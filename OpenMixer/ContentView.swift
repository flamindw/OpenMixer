import SwiftUI
import ServiceManagement

/// The OpenMixer menu bar panel.
struct ContentView: View {
    let mixer: Mixer

    @State private var expandedAppID: String?
    @State private var listHeight: CGFloat = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            outputSection
            Divider()
            appsSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Image(systemName: "slider.vertical.3")
                .foregroundStyle(.tint)
            Text("OpenMixer")
                .font(.headline)
            Spacer()
        }
    }

    // MARK: - Output device

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Output Device", selection: Binding(
                get: { mixer.defaultOutput?.id },
                set: { id in
                    if let device = mixer.devices.first(where: { $0.id == id }) {
                        mixer.setDefaultOutput(device)
                    }
                }
            )) {
                ForEach(mixer.devices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .labelsHidden()

            HStack(spacing: 8) {
                Button {
                    mixer.setMasterMuted(!mixer.masterMuted)
                } label: {
                    Image(systemName: speakerSymbol(volume: mixer.masterVolume, muted: mixer.masterMuted))
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .disabled(!mixer.canMuteMaster)
                .help(mixer.masterMuted ? "Unmute" : "Mute")

                Slider(value: Binding(
                    get: { mixer.masterVolume },
                    set: { mixer.setMasterVolume($0) }
                ), in: 0...1)
                .disabled(!mixer.canAdjustMasterVolume)

                Text(mixer.masterVolume, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    // MARK: - Apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Applications")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if mixer.apps.isEmpty {
                ContentUnavailableView(
                    "No Apps Playing",
                    systemImage: "speaker.slash",
                    description: Text("Apps appear here when they play audio.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(mixer.apps) { app in
                            AppRowView(
                                app: app,
                                mixer: mixer,
                                isExpanded: Binding(
                                    get: { expandedAppID == app.id },
                                    set: { expandedAppID = $0 ? app.id : nil }
                                )
                            )
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                // A ScrollView has no ideal height of its own, so in a self-sizing menu bar
                // window it would collapse to zero. Size it to its content, capped at 420pt.
                .frame(height: min(max(listHeight, 44), 420))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            Button("Quit OpenMixer") {
                mixer.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .font(.callout)
    }
}

/// SF Symbol reflecting a volume level.
func speakerSymbol(volume: Float, muted: Bool) -> String {
    if muted || volume == 0 { return "speaker.slash.fill" }
    switch volume {
    case ..<0.34: return "speaker.wave.1.fill"
    case ..<0.67: return "speaker.wave.2.fill"
    default: return "speaker.wave.3.fill"
    }
}

#Preview {
    ContentView(mixer: Mixer())
}
