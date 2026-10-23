import SwiftUI

@main struct OpenMixerApp: App {
    @State private var mixer = Mixer()

    var body: some Scene {
        MenuBarExtra("OpenMixer", systemImage: "slider.vertical.3") {
            ContentView(mixer: mixer)
        }
        .menuBarExtraStyle(.window)
    }
}
