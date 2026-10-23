import CoreAudio
import Foundation

enum AppTapError: LocalizedError {
    case createTap(OSStatus)
    case createAggregate(OSStatus)
    case createIOProc(OSStatus)
    case start(OSStatus)

    var errorDescription: String? {
        switch self {
        case .createTap(let status):
            "Couldn't tap app audio (error \(status)). Make sure OpenMixer is allowed under System Settings › Privacy & Security › Screen & System Audio Recording."
        case .createAggregate(let status):
            "Couldn't create the routing device (error \(status))."
        case .createIOProc(let status):
            "Couldn't attach the audio processor (error \(status))."
        case .start(let status):
            "Couldn't start audio (error \(status))."
        }
    }
}

/// Intercepts one app's audio: a muted-when-tapped process tap feeds a private aggregate
/// device whose IOProc applies the user's settings and plays the result on `outputDeviceUID`.
final class AppTap {
    let processObjects: Set<AudioObjectID>
    let outputDeviceUID: String
    private(set) var sampleRate: Double = 48_000

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let processor = TapProcessor()
    private let ioQueue = DispatchQueue(label: "OpenMixer.IO", qos: .userInteractive)

    init(name: String, processObjects: Set<AudioObjectID>, outputDeviceUID: String, settings: AppSettings) throws {
        self.processObjects = processObjects
        self.outputDeviceUID = outputDeviceUID

        // 1. Tap the app's processes and silence their normal output.
        let description = CATapDescription(stereoMixdownOfProcesses: Array(processObjects).sorted())
        description.uuid = UUID()
        description.name = "OpenMixer – \(name)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw AppTapError.createTap(status) }

        // 2. Build a private aggregate device: output device + the tap as an input.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenMixer – \(name)",
            kAudioAggregateDeviceUIDKey: "com.openmixer.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]

        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw AppTapError.createAggregate(status)
        }

        sampleRate = AudioHAL.nominalSampleRate(aggregateID) ?? 48_000

        // 3. Attach the processor and start playback.
        processor.update(gain: settings.effectiveGain, eqGainsDB: settings.eq, sampleRate: sampleRate)
        processor.primeGain(settings.effectiveGain)

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue, processor.makeIOBlock())
        guard status == noErr else {
            teardown()
            throw AppTapError.createIOProc(status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            teardown()
            throw AppTapError.start(status)
        }
    }

    func apply(_ settings: AppSettings) {
        processor.update(gain: settings.effectiveGain, eqGainsDB: settings.eq, sampleRate: sampleRate)
    }

    func invalidate() {
        teardown()
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
