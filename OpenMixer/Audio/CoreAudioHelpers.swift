import CoreAudio
import AudioToolbox
import Foundation

/// Thin, synchronous wrappers around the C-based Core Audio property API.
enum AudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    // MARK: - Generic accessors

    /// Reads a fixed-size (trivial) property value.
    static func get<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) -> T? {
        var address = address(selector, scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    @discardableResult
    static func set<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        value: T
    ) -> Bool {
        var address = address(selector, scope)
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeBytes(of: value) { bytes in
            AudioObjectSetPropertyData(object, &address, 0, nil, size, bytes.baseAddress!)
        }
        return status == noErr
    }

    static func isSettable(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = address(selector, scope)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = address(selector, scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objectIDs(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }

    // MARK: - Devices

    static var defaultOutputDevice: AudioObjectID {
        get { get(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown)) ?? AudioObjectID(kAudioObjectUnknown) }
        set { set(system, kAudioHardwarePropertyDefaultOutputDevice, value: newValue) }
    }

    static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        !objectIDs(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func name(_ object: AudioObjectID) -> String? {
        string(object, kAudioObjectPropertyName)
    }

    static func transportType(_ device: AudioObjectID) -> UInt32 {
        get(device, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
    }

    /// The device's main output volume (0...1), using the virtual main volume that
    /// works across devices with per-channel or main-element controls.
    static func volume(_ device: AudioObjectID) -> Float? {
        get(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, initial: Float32(0))
    }

    static func setVolume(_ device: AudioObjectID, _ volume: Float) {
        set(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, value: Float32(volume))
    }

    static func canSetVolume(_ device: AudioObjectID) -> Bool {
        isSettable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        (get(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0)) ?? 0) != 0
    }

    static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
        set(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(muted ? 1 : 0))
    }

    static func canMute(_ device: AudioObjectID) -> Bool {
        isSettable(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        get(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    // MARK: - Processes

    static var processObjects: [AudioObjectID] {
        objectIDs(system, kAudioHardwarePropertyProcessObjectList)
    }

    static func pid(ofProcess process: AudioObjectID) -> pid_t? {
        get(process, kAudioProcessPropertyPID, initial: pid_t(-1))
    }

    static func bundleID(ofProcess process: AudioObjectID) -> String? {
        string(process, kAudioProcessPropertyBundleID)
    }

    static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        (get(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
    }
}
