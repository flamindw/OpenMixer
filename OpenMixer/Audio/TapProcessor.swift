import CoreAudio
import Foundation
import os

/// Normalized biquad filter coefficients (a0 == 1).
nonisolated struct Biquad: Sendable {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    static let identity = Biquad()

    /// RBJ Audio EQ Cookbook low shelf (slope S = 1).
    static func lowShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        guard gainDB != 0 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0), alpha = sin(w0) / 2 * sqrt(2.0)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        let a0 = (a + 1) + (a - 1) * cosW + twoSqrtAAlpha
        return Biquad(
            b0: Float(a * ((a + 1) - (a - 1) * cosW + twoSqrtAAlpha) / a0),
            b1: Float(2 * a * ((a - 1) - (a + 1) * cosW) / a0),
            b2: Float(a * ((a + 1) - (a - 1) * cosW - twoSqrtAAlpha) / a0),
            a1: Float(-2 * ((a - 1) + (a + 1) * cosW) / a0),
            a2: Float(((a + 1) + (a - 1) * cosW - twoSqrtAAlpha) / a0)
        )
    }

    /// RBJ Audio EQ Cookbook high shelf (slope S = 1).
    static func highShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        guard gainDB != 0 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0), alpha = sin(w0) / 2 * sqrt(2.0)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        let a0 = (a + 1) - (a - 1) * cosW + twoSqrtAAlpha
        return Biquad(
            b0: Float(a * ((a + 1) + (a - 1) * cosW + twoSqrtAAlpha) / a0),
            b1: Float(-2 * a * ((a - 1) + (a + 1) * cosW) / a0),
            b2: Float(a * ((a + 1) + (a - 1) * cosW - twoSqrtAAlpha) / a0),
            a1: Float(2 * ((a - 1) - (a + 1) * cosW) / a0),
            a2: Float(((a + 1) - (a - 1) * cosW - twoSqrtAAlpha) / a0)
        )
    }

    /// RBJ Audio EQ Cookbook peaking EQ.
    static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        guard gainDB != 0 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0), alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha / a
        return Biquad(
            b0: Float((1 + alpha * a) / a0),
            b1: Float(-2 * cosW / a0),
            b2: Float((1 - alpha * a) / a0),
            a1: Float(-2 * cosW / a0),
            a2: Float((1 - alpha / a) / a0)
        )
    }
}

/// Parameters handed from the UI thread to the real-time audio thread.
nonisolated struct TapParameters: Sendable {
    var gain: Float = 1
    var bands: (Biquad, Biquad, Biquad) = (.identity, .identity, .identity)
    var eqEnabled = false
}

/// Per-channel filter memory for one biquad (transposed direct form II).
nonisolated private struct FilterState {
    var z1: Float = 0, z2: Float = 0

    @inline(__always)
    mutating func process(_ x: Float, _ c: Biquad) -> Float {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

/// Real-time processor attached to an aggregate device's IOProc. It reads the tapped
/// app audio from the input side, applies gain and EQ, and writes it to the output device.
///
/// The render path never allocates or blocks: parameter updates are picked up with a
/// try-lock, so the audio thread simply keeps the previous parameters if the UI holds the lock.
nonisolated final class TapProcessor: @unchecked Sendable {
    static let bandFrequencies: [Double] = [100, 1_000, 8_000]

    private let pending = OSAllocatedUnfairLock(initialState: TapParameters())
    private var active = TapParameters()
    private var smoothedGain: Float = 1
    /// Filter memory for 3 bands x L/R, preallocated so the render path never allocates.
    private let filters: UnsafeMutablePointer<FilterState>

    private let scratchCapacity = 16_384
    private let scratch: UnsafeMutablePointer<Float>

    init() {
        scratch = .allocate(capacity: scratchCapacity * 2)
        scratch.initialize(repeating: 0, count: scratchCapacity * 2)
        filters = .allocate(capacity: 6)
        filters.initialize(repeating: FilterState(), count: 6)
    }

    deinit {
        scratch.deallocate()
        filters.deallocate()
    }

    /// Called from the main thread whenever the user changes a setting.
    func update(gain: Float, eqGainsDB: [Float], sampleRate: Double) {
        var params = TapParameters()
        params.gain = gain
        let gains = eqGainsDB.map(Double.init) + [0, 0, 0]
        let freqs = Self.bandFrequencies
        params.eqEnabled = gains.prefix(3).contains { $0 != 0 }
        params.bands = (
            .lowShelf(frequency: freqs[0], gainDB: gains[0], sampleRate: sampleRate),
            .peaking(frequency: freqs[1], q: 0.9, gainDB: gains[1], sampleRate: sampleRate),
            .highShelf(frequency: freqs[2], gainDB: gains[2], sampleRate: sampleRate)
        )
        let snapshot = params
        pending.withLock { $0 = snapshot }
    }

    /// Initial parameters can skip the gain ramp so audio starts at the right level.
    func primeGain(_ gain: Float) {
        smoothedGain = gain
    }

    func makeIOBlock() -> AudioDeviceIOBlock {
        { [self] _, input, _, output, _ in
            self.render(input: input, output: output)
        }
    }

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        if let latest = pending.withLockIfAvailable({ $0 }) {
            active = latest
        }

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        // The tap's stream is appended after any input streams of the output device,
        // so it is always the last input buffer.
        guard let tapBuffer = inputs.last,
              let tapData = tapBuffer.mData?.assumingMemoryBound(to: Float.self),
              tapBuffer.mNumberChannels > 0 else {
            silence(outputs)
            return
        }

        let inChannels = Int(tapBuffer.mNumberChannels)
        let frames = min(Int(tapBuffer.mDataByteSize) / (MemoryLayout<Float>.size * inChannels), scratchCapacity)

        // Process into an interleaved stereo scratch buffer.
        let params = active
        var gain = smoothedGain
        let target = params.gain
        let f = filters
        for i in 0..<frames {
            var l = tapData[i * inChannels]
            var r = inChannels > 1 ? tapData[i * inChannels + 1] : l

            if params.eqEnabled {
                l = f[0].process(l, params.bands.0); r = f[1].process(r, params.bands.0)
                l = f[2].process(l, params.bands.1); r = f[3].process(r, params.bands.1)
                l = f[4].process(l, params.bands.2); r = f[5].process(r, params.bands.2)
            }

            // One-pole smoothing avoids zipper noise while dragging sliders.
            gain += (target - gain) * 0.002
            scratch[i * 2] = max(-1, min(1, l * gain))
            scratch[i * 2 + 1] = max(-1, min(1, r * gain))
        }
        smoothedGain = gain

        // Fan the stereo signal out across the output device's buffers/channels.
        var channelOffset = 0
        for buffer in outputs {
            guard let out = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            for frame in 0..<outFrames {
                for c in 0..<channels {
                    let global = channelOffset + c
                    let sample: Float = (frame < frames && global < 2) ? scratch[frame * 2 + global] : 0
                    out[frame * channels + c] = sample
                }
            }
            channelOffset += channels
        }
    }

    private func silence(_ outputs: UnsafeMutableAudioBufferListPointer) {
        for buffer in outputs {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }
}
