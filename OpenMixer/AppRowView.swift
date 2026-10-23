import SwiftUI

/// A single app's controls: mute, volume/boost, and an expandable EQ + output routing panel.
struct AppRowView: View {
    let app: AudioApp
    let mixer: Mixer
    @Binding var isExpanded: Bool

    private static let bandNames = ["Bass", "Mid", "Treble"]

    private var settings: AppSettings { mixer.settings(for: app.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .opacity(app.isPlaying ? 1 : 0.5)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(app.name)
                            .lineLimit(1)
                        if settings.outputDeviceUID != nil || settings.eq.contains(where: { $0 != 0 }) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Custom EQ or output device")
                        }
                    }
                    volumeControls
                }

                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Effects & Output")
            }

            if isExpanded {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let error = mixer.errors[app.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(isExpanded ? 0.6 : 0.3), in: .rect(cornerRadius: 8))
    }

    private var volumeControls: some View {
        HStack(spacing: 6) {
            Button {
                mixer.update(app.id) { $0.muted.toggle() }
            } label: {
                Image(systemName: speakerSymbol(volume: min(settings.volume, 1), muted: settings.muted))
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(settings.muted ? "Unmute" : "Mute")

            Slider(value: Binding(
                get: { settings.volume },
                set: { newValue in
                    // Snap to 100% so it's easy to return to the original level.
                    let snapped = abs(newValue - 1) < 0.03 ? 1 : newValue
                    mixer.update(app.id) { $0.volume = snapped }
                }
            ), in: 0...2)
            .controlSize(.small)

            Text(settings.volume, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(settings.volume > 1 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Equalizer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Self.bandNames.indices, id: \.self) { band in
                HStack(spacing: 6) {
                    Text(Self.bandNames[band])
                        .font(.caption)
                        .frame(width: 44, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(settings.eq[band]) },
                        set: { newValue in
                            let rounded = Float((newValue * 2).rounded() / 2)
                            mixer.update(app.id) { $0.eq[band] = rounded }
                        }
                    ), in: -12...12)
                    .controlSize(.small)
                    Text("\(settings.eq[band], specifier: "%+.1f") dB")
                        .monospacedDigit()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
            }

            Picker("Output", selection: Binding(
                get: { settings.outputDeviceUID },
                set: { uid in mixer.update(app.id) { $0.outputDeviceUID = uid } }
            )) {
                Text("System Default").tag(String?.none)
                Divider()
                ForEach(mixer.devices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
            .font(.caption)

            HStack {
                Spacer()
                Button("Reset") {
                    mixer.reset(app.id)
                }
                .controlSize(.small)
                .disabled(!settings.needsTap)
            }
        }
    }
}
