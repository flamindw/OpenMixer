import AppKit
import CoreAudio

/// An output-capable audio device.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

/// One app (possibly made up of several helper processes) that is producing audio.
struct AudioApp: Identifiable {
    /// Stable identity used for grouping and persistence (bundle ID or bundle path).
    let id: String
    let name: String
    let icon: NSImage
    var processObjects: Set<AudioObjectID>
    var isPlaying: Bool
}

/// User-adjustable settings for an app, persisted between launches.
struct AppSettings: Codable, Equatable {
    /// Linear gain, 0...2 (up to +100% boost).
    var volume: Float = 1
    var muted = false
    /// Gains in dB for the bass / mid / treble bands.
    var eq: [Float] = [0, 0, 0]
    /// UID of the output device, or `nil` to follow the system default.
    var outputDeviceUID: String?

    static let `default` = AppSettings()

    var effectiveGain: Float { muted ? 0 : volume }

    /// When settings are untouched, OpenMixer leaves the app's audio completely alone.
    var needsTap: Bool { self != .default }
}
