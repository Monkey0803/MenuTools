# MenuTools

[简体中文](README.md) | English

A lightweight system toolkit that lives in the macOS menu bar. MenuTools uses the native **Liquid Glass** design introduced in macOS 26 and automatically adapts to light and dark appearance.

![platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue)
![swift](https://img.shields.io/badge/Swift-6-orange)
![license](https://img.shields.io/badge/license-MIT-green)

## Features

### Quick Actions

| Feature | Description |
|---|---|
| Open Finder path in a terminal | Opens the directory of the frontmost Finder window in Terminal, iTerm2, Warp, Ghostty, kitty, Alacritty, or the selected terminal app. |
| Toggle appearance | Switches between light and dark appearance and follows the system theme in real time. |

### System Toggles

| Toggle | Description |
|---|---|
| Prevent sleep | Uses an IOKit power assertion to prevent display sleep while enabled. |
| Show hidden files | Toggles Finder hidden-file visibility and restarts Finder automatically. |
| Mute | Toggles system output mute. |
| Auto-hide Dock | Controls Dock auto-hide behavior. |
| Auto-hide menu bar | Controls menu bar auto-hide behavior. |
| Night Shift | Toggles Night Shift and stays synchronized with Control Center when supported. |

### Information and Cleanup

| Feature | Description |
|---|---|
| Bluetooth battery levels | Shows AirPods left/right/case levels, BLE keyboard and mouse batteries, and classic Bluetooth headset levels when reported by macOS. |
| Clean DerivedData | Shows the size of Xcode DerivedData and cleans it with one click. |
| Clear clipboard | Shows the current clipboard item count and clears the clipboard. |
| Check for updates | Checks for new releases and opens the download page when an update is available. |

### Personalization

- Choose from 8 menu bar icons based on SF Symbols.
- Liquid Glass UI with `GlassEffectContainer`, tinted glass tiles, and morphing transitions.
- Staggered section entrance animations, SF Symbol transitions, and numeric text transitions.

## Installation and Build

### Download

Latest release: [MenuTools v1.0.0](https://github.com/Monkey0803/MenuTools/releases/tag/v1.0.0)

Download `MenuTools-1.0.0.zip`, extract it, and move `MenuTools.app` to the Applications folder.

> The current release uses a self-signed certificate. macOS may require approval in **System Settings → Privacy & Security** the first time you open it.

### First Launch

If macOS blocks the app:

1. Double-click the app and wait for macOS to block it.
2. Open **System Settings → Privacy & Security**.
3. Find the security warning near the bottom of the page.
4. Click **Open Anyway**.
5. Confirm by clicking **Open** in the dialog that appears.

You can also right-click `MenuTools.app` in Finder and choose **Open**.

If the app still will not open, and you have verified that it came from this project's GitHub Release, run the following command from the directory containing the app:

```bash
sudo xattr -dr com.apple.quarantine MenuTools.app
```

> `xattr` removes the downloaded-file quarantine flag. Use it only for a trusted app from a verified source. Prefer **Open Anyway** and do not disable macOS Gatekeeper globally.

### Requirements

- macOS 26.0 or later. Liquid Glass APIs require macOS 26.
- Xcode 26 or a Swift 6 toolchain.
- Apple Silicon is required by the current build.

### Build from Source

```bash
git clone https://github.com/Monkey0803/MenuTools.git
cd MenuTools
./build.sh
open dist/MenuTools.app
```

The build script compiles the Swift Package, assembles the app bundle, builds the Finder extension, and signs the result. The app is written to `dist/MenuTools.app`.

## Permissions

Some features request permissions the first time they are used:

| Permission | Purpose | Features |
|---|---|---|
| Automation → Finder | Reads the path of the frontmost Finder window. | Open Finder path in a terminal |
| Automation → System Events | Changes appearance, Dock, and menu bar settings. | Appearance, Dock, and menu bar toggles |
| Bluetooth | Reads battery levels from connected Bluetooth devices. | Bluetooth battery levels |

If permission was denied, enable it again in **System Settings → Privacy & Security**. Mute, prevent sleep, Night Shift, cleanup features, and clipboard cleanup do not require these permissions.

## Technical Implementation

| Module | Implementation |
|---|---|
| Menu bar app | SwiftUI `MenuBarExtra` with window style and `LSUIElement` |
| Liquid Glass | Native macOS 26 `glassEffect`, `GlassEffectContainer`, and `glassEffectID` |
| Finder path | AppleScript through `NSAppleScript` |
| Appearance, Dock, and menu bar | AppleScript through System Events |
| Prevent sleep | IOKit `IOPMAssertionCreateWithName` |
| Night Shift | Runtime calls to the private CoreBrightness `CBBlueLightClient` API with capability checks |
| Bluetooth battery levels | IORegistry for AirPods, private IOBluetooth getters for classic Bluetooth devices, and CoreBluetooth GATT service `180F/2A19` for BLE devices |
| DerivedData | Background file-system size calculation and cleanup |
| Update checks | GitHub Releases API with a lightweight appcast JSON fallback |

Project structure:

```text
MenuTools/
├── Package.swift               # Swift Package Manager manifest
├── build.sh                    # Build, package, and sign script
├── Resources/                  # Info.plist, entitlements, and icon
├── Scripts/                    # Icon generation and API validation scripts
└── Sources/MenuTools/
    ├── MenuToolsApp.swift      # App entry point and menu bar configuration
    ├── MenuPanelView.swift     # Main Liquid Glass panel
    └── Services/               # Single-responsibility services
```

## Releases and Updates

The update checker uses the GitHub Releases API by default. To publish a release:

1. Update `CFBundleShortVersionString` in `Resources/Info.plist`.
2. Build and package `MenuTools.app`, optionally as a zip, DMG, or PKG.
3. Create a GitHub Release with a tag such as `v1.1.0` and attach the installer package.

The app checks for updates automatically with a 24-hour throttle. Users can also trigger a manual check from the settings window. When an update is available, MenuTools opens the direct release asset when possible, or the release page as a fallback.

An appcast JSON source is also supported:

```json
{
  "version": "1.1.0",
  "notes": "Release notes",
  "url": "https://example.com/MenuTools-1.1.0.zip"
}
```

Override the update source for testing:

```bash
defaults write com.qoder.menutools updateFeedURL "https://your-server/appcast.json"
defaults delete com.qoder.menutools updateFeedURL
```

## Known Limitations

- Night Shift and classic Bluetooth headset battery levels depend on private system APIs. They may stop working after a major macOS update; capability checks make the app fail gracefully when the APIs are unavailable. Validation scripts are included in `Scripts/`.
- Bluetooth devices that do not report battery levels cannot be displayed with a percentage.
- AirPods case battery levels may only be reported when the case is open or the device has just connected.
- The current release is self-signed and is not notarized by Apple.

## Acknowledgements

The smooth-scrolling design was inspired by the technical approach of [Mos](https://github.com/Caldis/Mos), including event templates, frame-based interpolation, peak filtering, buffer/current easing, and modifier-key controls. MenuTools is an independent implementation and does not copy Mos source code. Mos is licensed under [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/), which is not compatible with this project's MIT license; it is credited here as a source of technical inspiration only.

## License

[MIT](LICENSE)
