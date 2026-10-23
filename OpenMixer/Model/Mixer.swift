import AppKit
import CoreAudio
import Darwin
import Observation
import UniformTypeIdentifiers

/// Central model: tracks output devices and audio-producing apps, owns the per-app taps,
/// and persists per-app settings.
@Observable
final class Mixer {
    private(set) var devices: [AudioDevice] = []
    private(set) var defaultOutput: AudioDevice?
    private(set) var masterVolume: Float = 0
    private(set) var masterMuted = false
    private(set) var canAdjustMasterVolume = false
    private(set) var canMuteMaster = false
    private(set) var apps: [AudioApp] = []
    private(set) var settings: [String: AppSettings] = [:]
    private(set) var errors: [String: String] = [:]

    private struct Identity {
        let key: String
        let name: String
        let icon: NSImage
        /// True for regular, user-facing apps (as opposed to system daemons and agents).
        let isUserApp: Bool
    }

    /// Describes a tap configuration so we don't keep retrying one that already failed.
    private struct TapConfig: Equatable {
        let processObjects: Set<AudioObjectID>
        let outputDeviceUID: String
    }

    @ObservationIgnored private var taps: [String: AppTap] = [:]
    @ObservationIgnored private var failedConfigs: [String: TapConfig] = [:]
    @ObservationIgnored private var runningApps: [String: AudioApp] = [:]
    @ObservationIgnored private var identityCache: [pid_t: Identity] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private static let settingsKey = "OpenMixer.AppSettings"

    init() {
        loadSettings()
        refresh()
        installListeners()

        // Polling picks up changes without listeners, e.g. an app starting/stopping playback
        // or the volume being changed with the keyboard.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refresh()
            }
        }
    }

    // MARK: - Public API

    func settings(for appID: String) -> AppSettings {
        settings[appID] ?? .default
    }

    func update(_ appID: String, _ change: (inout AppSettings) -> Void) {
        var value = settings(for: appID)
        change(&value)
        settings[appID] = value == .default ? nil : value
        failedConfigs[appID] = nil
        saveSettings()
        if let app = runningApps[appID] {
            reconcileTap(for: app)
        }
    }

    func reset(_ appID: String) {
        update(appID) { $0 = .default }
    }

    func setMasterVolume(_ volume: Float) {
        guard let device = defaultOutput else { return }
        AudioHAL.setVolume(device.id, volume)
        masterVolume = volume
    }

    func setMasterMuted(_ muted: Bool) {
        guard let device = defaultOutput else { return }
        AudioHAL.setMuted(device.id, muted)
        masterMuted = muted
    }

    func setDefaultOutput(_ device: AudioDevice) {
        AudioHAL.defaultOutputDevice = device.id
        refresh()
    }

    /// Tears down all taps so apps immediately return to their normal output.
    func shutdown() {
        refreshTask?.cancel()
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
    }

    // MARK: - Refresh

    func refresh() {
        refreshDevices()
        refreshApps()
    }

    private func refreshDevices() {
        let newDevices = AudioHAL.objectIDs(AudioHAL.system, kAudioHardwarePropertyDevices).compactMap { id -> AudioDevice? in
            guard AudioHAL.hasOutputStreams(id),
                  let uid = AudioHAL.deviceUID(id),
                  !uid.hasPrefix("com.openmixer.") else { return nil }
            return AudioDevice(id: id, uid: uid, name: AudioHAL.name(id) ?? "Unknown Device")
        }
        if newDevices != devices { devices = newDevices }

        let defaultID = AudioHAL.defaultOutputDevice
        let newDefault = newDevices.first { $0.id == defaultID }
        if newDefault != defaultOutput { defaultOutput = newDefault }

        guard let device = newDefault else { return }
        let volume = AudioHAL.volume(device.id) ?? 1
        if volume != masterVolume { masterVolume = volume }
        let muted = AudioHAL.isMuted(device.id)
        if muted != masterMuted { masterMuted = muted }
        let canSet = AudioHAL.canSetVolume(device.id)
        if canSet != canAdjustMasterVolume { canAdjustMasterVolume = canSet }
        let canMute = AudioHAL.canMute(device.id)
        if canMute != canMuteMaster { canMuteMaster = canMute }
    }

    private func refreshApps() {
        var grouped: [String: AudioApp] = [:]
        var userApps = Set<String>()
        var livePIDs = Set<pid_t>()

        for process in AudioHAL.processObjects {
            guard let pid = AudioHAL.pid(ofProcess: process), pid > 0, pid != ownPID else { continue }
            livePIDs.insert(pid)
            let identity = identity(for: pid, bundleID: AudioHAL.bundleID(ofProcess: process))
            var app = grouped[identity.key] ?? AudioApp(
                id: identity.key, name: identity.name, icon: identity.icon, processObjects: [], isPlaying: false
            )
            app.processObjects.insert(process)
            if AudioHAL.isRunningOutput(process) { app.isPlaying = true }
            if identity.isUserApp { userApps.insert(identity.key) }
            grouped[identity.key] = app
        }

        identityCache = identityCache.filter { livePIDs.contains($0.key) }
        runningApps = grouped

        // Show every open user-facing app that uses audio, plus anything currently playing
        // or customized. Background daemons stay hidden unless they make sound.
        let visible = grouped.values
            .filter { $0.isPlaying || userApps.contains($0.id) || settings[$0.id] != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if visible.map(\.id) != apps.map(\.id) || visible.map(\.isPlaying) != apps.map(\.isPlaying) {
            apps = visible
        }
        for app in grouped.values { reconcileTap(for: app) }
        for key in taps.keys where grouped[key] == nil {
            taps.removeValue(forKey: key)?.invalidate()
        }
    }

    // MARK: - Taps

    /// Ensures the app has a tap matching its current settings, or none if untouched.
    private func reconcileTap(for app: AudioApp) {
        let appSettings = settings(for: app.id)
        guard appSettings.needsTap, let deviceUID = outputDeviceUID(for: appSettings) else {
            taps.removeValue(forKey: app.id)?.invalidate()
            errors[app.id] = nil
            return
        }

        let config = TapConfig(processObjects: app.processObjects, outputDeviceUID: deviceUID)
        if let tap = taps[app.id], tap.processObjects == config.processObjects, tap.outputDeviceUID == deviceUID {
            tap.apply(appSettings)
            return
        }
        guard failedConfigs[app.id] != config else { return }

        taps.removeValue(forKey: app.id)?.invalidate()
        do {
            taps[app.id] = try AppTap(
                name: app.name, processObjects: app.processObjects, outputDeviceUID: deviceUID, settings: appSettings
            )
            errors[app.id] = nil
        } catch {
            failedConfigs[app.id] = config
            errors[app.id] = error.localizedDescription
        }
    }

    /// The app's chosen device if it's connected, otherwise the system default.
    private func outputDeviceUID(for settings: AppSettings) -> String? {
        if let uid = settings.outputDeviceUID, devices.contains(where: { $0.uid == uid }) {
            return uid
        }
        return defaultOutput?.uid
    }

    // MARK: - Listeners

    private func installListeners() {
        let selectors = [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyProcessObjectList,
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(AudioHAL.system, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    // MARK: - App identity

    private func identity(for pid: pid_t, bundleID: String?) -> Identity {
        if let cached = identityCache[pid] { return cached }
        let identity = resolveIdentity(pid: pid, bundleID: bundleID)
        identityCache[pid] = identity
        return identity
    }

    /// Groups helper processes with their parent app. Helpers (e.g. "Google Chrome Helper")
    /// live inside the main app's bundle, so the outermost `.app` in the executable path
    /// identifies the app the user actually sees.
    private func resolveIdentity(pid: pid_t, bundleID: String?) -> Identity {
        if let path = executablePath(of: pid), let appPath = outermostAppBundle(in: path) {
            let key = Bundle(path: appPath)?.bundleIdentifier ?? appPath
            var name = FileManager.default.displayName(atPath: appPath)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            // It's a user-facing app if the bundle is running as a regular (Dock) app.
            let isUserApp = NSWorkspace.shared.runningApplications.contains {
                $0.activationPolicy == .regular && $0.bundleURL?.standardizedFileURL.path == appPath
            }
            return Identity(key: key, name: name, icon: NSWorkspace.shared.icon(forFile: appPath), isUserApp: isUserApp)
        }

        // WebKit's GPU/media processes play audio on behalf of Safari and other web views.
        if let bundleID, bundleID.hasPrefix("com.apple.WebKit") {
            let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            let icon = safari.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
            return Identity(key: "com.apple.WebKit", name: "Safari & Web Content", icon: icon, isUserApp: true)
        }

        let running = NSRunningApplication(processIdentifier: pid)
        let fallbackName = executablePath(of: pid).map { ($0 as NSString).lastPathComponent }
        return Identity(
            key: bundleID ?? running?.bundleIdentifier ?? "pid.\(pid)",
            name: running?.localizedName ?? fallbackName ?? bundleID ?? "Process \(pid)",
            icon: running?.icon ?? NSWorkspace.shared.icon(for: .unixExecutable),
            isUserApp: running?.activationPolicy == .regular
        )
    }

    private func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private func outermostAppBundle(in path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[...index]))
    }

    // MARK: - Persistence

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey),
              let decoded = try? JSONDecoder().decode([String: AppSettings].self, from: data) else { return }
        settings = decoded
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }
}
