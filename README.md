# OpenMixer

A free, open-source per-app audio mixer for macOS, inspired by SoundSource.

OpenMixer lives in your menu bar and lets you control the sound of each app individually, without installing an audio driver.

## Features

- **Per-app volume:** set any app from 0% to 200%, so you can turn quiet apps up past their normal level.
- **Per-app mute.**
- **3-band EQ per app:** bass, mid and treble, ±12 dB each.
- **Per-app output routing:** send one app to your headphones and everything else to your speakers.
- **System output control:** pick the default output device and set the main volume.
- **App grouping:** helper processes are grouped under their parent app, so Chrome or Discord each appear once.
- **Saved settings:** each app's settings are remembered between launches.
- **Launch at Login.**

## Download & install

1. Download **OpenMixer.dmg** from the [latest release](https://github.com/flamindw/OpenMixer/releases/latest).
2. Open the disk image and drag **OpenMixer** into **Applications**.
3. Open OpenMixer from Applications. It appears as a slider icon in the menu bar, with no Dock icon or window.

**First launch only:** OpenMixer isn't notarized by Apple yet, so macOS shows *"OpenMixer" Not Opened – Apple could not verify…*. To allow it:

1. Click **Done** on the warning.
2. Open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to the OpenMixer message.
3. Confirm with **Open Anyway** and your password.

After that, OpenMixer opens normally with a double-click.

## Requirements

- macOS 14.2 (Sonoma) or later, on Apple silicon or Intel. OpenMixer relies on Core Audio process taps, which were introduced in macOS 14.2.
- Xcode 26 or later to build from source.

## Building from source

1. Open `OpenMixer.xcodeproj` in Xcode.
2. Select your own development team under **Signing & Capabilities**.
3. Build and run (⌘R).

## Permissions

The first time you adjust an app, macOS asks for permission under **System Settings › Privacy & Security › Screen & System Audio Recording**. OpenMixer needs this to capture an app's audio so it can process and replay it.

## How it works

Apps you haven't changed are left completely alone. When you adjust an app, OpenMixer:

1. Creates a Core Audio **process tap** on that app's processes, with *muted-when-tapped* behaviour, so the original output is silenced.
2. Creates a private **aggregate device** that combines the tap with the chosen output device.
3. Runs a real-time IOProc on that device that applies gain and biquad EQ filters, then plays the result.

| File | Purpose |
|---|---|
| `Audio/CoreAudioHelpers.swift` | Swift wrappers around the Core Audio property API |
| `Audio/TapProcessor.swift` | Allocation-free, lock-free real-time gain and EQ processing |
| `Audio/AppTap.swift` | Creates and tears down a tap and aggregate device for one app |
| `Model/Mixer.swift` | Discovers devices and apps, reconciles taps, persists settings |
| `ContentView.swift`, `AppRowView.swift` | The SwiftUI menu bar panel |
| `OpenMixerApp.swift` | App entry point (menu bar scene) |

All source files live in the `OpenMixer/` folder.

App Sandbox is disabled, because process taps and process lookup require it. This means OpenMixer can't be distributed through the Mac App Store.

## Known limitations

- Output is stereo. Extra channels on multichannel devices are left silent for processed apps.
- Audio from Safari and other WebKit views comes from shared system processes, so it appears as one "Safari & Web Content" entry.

## License

[MIT](LICENSE)
