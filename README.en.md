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

### Quick Action Center

| Feature | Description |
|---|---|
| Lock Screen | Immediately locks the current user session. |
| Empty Trash | Empties the Trash through Finder. |
| Restart Finder | Restarts Finder to recover from an abnormal state. |
| Flush DNS | Flushes the local DNS cache and restarts mDNSResponder. |
| System Settings | Opens macOS System Settings. |
| Screenshot to Clipboard | Captures the screen and copies it directly to the clipboard. |

### Screenshot Tools

| Feature | Description |
|---|---|
| Full-screen / window capture | Captures the full screen, frontmost window, or a custom area with independent global shortcuts. |
| Repeat last area | Stores the latest custom region for one-click recapture. |
| Scrolling screenshot | Samples stable frames while you scroll and stitches them when the shortcut finishes the session. |
| Screenshot annotation | Includes pen, arrows, shapes, highlight, mosaic, and text tools. |

### App Volume Management

| Feature | Description |
|---|---|
| System output volume | Controls the current default output device and stays synchronized with system mute. |
| Per-app volume | Independently adjusts active apps from 0–100% with continuous sliders. |
| Volume profiles | Remembers levels by root app bundle ID and groups helper processes into their parent app. |

### Productivity Tools

| Feature | Description |
|---|---|
| App Launcher | Search and launch installed apps, with favorites and recent-app ordering. |
| Scenes | Apply Work, Presentation, or Night presets manually. |
| Window Management | Use 58 layouts, edge snapping, layout presets, app rules, multi-window tiling, cross-display movement, and saved window sizes. |
| Focus | Toggle the system Focus state and open Focus settings. |
| Global scene shortcuts | Record global shortcuts for Work, Presentation, and Night scenes. |

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
| Clipboard History | Keeps recent text and images with search, pin, delete, and copy actions. |
| System Resources | Shows CPU, memory pressure, free disk space, and network rates. |
| Network Traffic | Per-app live upload/download rates, connection details, and 30-day history with interface/protocol filtering, quota alerts, redacted export, and data clearing. |
| Check for updates | Checks for new releases and opens the download page when an update is available. |

### System Information

| Feature | Description |
|---|---|
| Network Status | Shows Wi-Fi, network name, local IP, and VPN status; public IP and latency are on-demand. |
| Battery Health | Shows built-in battery health, cycle count, charge, and charging state; unavailable data degrades silently. |
| Displays | Shows built-in/external displays and their modes, with supported resolution and refresh-rate switching. |
| Storage Analysis | Analyzes DerivedData, caches, logs, and Downloads, with confirmation-gated cleanup for safe directories. |

### Personalization

- Choose from 8 menu bar icons based on SF Symbols.
- Liquid Glass UI with `GlassEffectContainer`, tinted glass tiles, and morphing transitions.
- Staggered section entrance animations, SF Symbol transitions, and numeric text transitions.

## Installation and Build

### Download

Current target release: [MenuTools v1.0.4](https://github.com/Monkey0803/MenuTools/releases/tag/v1.0.4)

Download `MenuTools-1.0.4.zip`, extract it, and move `MenuTools.app` to the Applications folder.

> Check each GitHub Release for its actual signing type. Without Developer ID and notarization credentials, packages use the project's self-signed certificate or ad-hoc signing and are not described as notarized.

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

### Network Traffic Validation

Network Traffic depends on the live output of the system `nettop` command. Run a short smoke test after a change or macOS major-version upgrade:

```bash
swift Scripts/test_network_traffic.swift --duration 30 --connections --strict
```

For an 8-hour stability run without generating extra download traffic:

```bash
swift Scripts/test_network_traffic.swift --duration 28800 --interval 10 --no-download --strict
```

The script reports sample duration, process-row counts, non-zero traffic rows, and a final summary. Then cross-check the matching app, rate, and connection details in MenuTools Settings.

## Permissions

Some features request permissions the first time they are used:

| Permission | Purpose | Features |
|---|---|---|
| Automation → Finder | Reads the path of the frontmost Finder window. | Open Finder path in a terminal |
| Automation → Finder | Empties the Trash. | Quick Action Center |
| Automation → System Events | Changes appearance, Dock, and menu bar settings. | Appearance, Dock, and menu bar toggles |
| Bluetooth | Reads battery levels from connected Bluetooth devices. | Bluetooth battery levels |
| Screen Recording | Allows screen capture. | Screenshot to Clipboard |
| Screen Recording | Allows window, area, and scrolling capture. | Screenshot Tools |
| System Audio Recording | Captures active app audio and replays it with an independent gain. | Per-app volume management |
| Accessibility | Reads and sets the position and size of the frontmost window. | Window Management |
| Accessibility | Receives global keyboard events and triggers scenes. | Global scene shortcuts, Focus |

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
| Quick Action Center | Process commands, Finder AppleScript, System Settings URL, and `screencapture` |
| Screenshot Tools | ScreenCaptureKit native-pixel capture, frozen selection, window capture, multi-display compositing, Vision motion estimation, PNG stitching, and OCR/QR recognition; captures can be copied to the clipboard or opened in the built-in annotator |
| App Volume Management | Public Core Audio Process Tap, a private aggregate device, and IOProc routing; routes only apps below 100% and destroys taps to restore original audio on exit or failure |
| Network Status | CoreWLAN, interface addresses, VPN state, and on-demand URLSession probes |
| Network Traffic | `/usr/bin/nettop` process sampling, SQLite/WAL history, diagnostics, quota alerts, and optional redacted exports |
| Battery Health | `system_profiler SPPowerDataType -json`, with silent fallback when unavailable |
| Displays | `NSScreen` and CoreGraphics display mode enumeration and switching |
| Storage Analysis | Background recursive measurement of selected directories; cleanup keeps directories and never touches Downloads |
| App Launcher | NSWorkspace app discovery, search, favorites, and launching |
| Scenes | Composes app launching, appearance, Focus, audio, desktop icons, and prevent-sleep actions |
| Window Management | Accessibility API for window position, size, and display movement; NSEvent edge snapping; persisted layout presets and app rules |
| Focus | Control Center accessibility script with a System Settings fallback |
| Global shortcuts | NSEvent global/local keyboard monitors, persistent bindings, and conflict detection |
| Update checks | Sparkle standard updater with Ed25519-signed appcast |

Project structure:

```text
MenuTools/
├── Package.swift               # Swift Package Manager manifest
├── build.sh                    # Build, package, and sign script
├── release.sh                  # Release checks, notarization, and packages
├── Resources/                  # Info.plist, entitlements, and icon
├── appcast.xml                 # Sparkle update feed template
├── Scripts/                    # Icon generation and API validation scripts
└── Sources/MenuTools/
    ├── MenuToolsApp.swift      # App entry point and menu bar configuration
    ├── MenuPanelView.swift     # Main Liquid Glass panel
    └── Services/               # Single-responsibility services
```

## Releases and Updates

Updates use [Sparkle](https://github.com/sparkle-project/Sparkle) for appcast checks, downloads, Ed25519 signature verification, installation, and relaunch. To publish a release:

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Configure a Developer ID certificate and a `notarytool` Keychain profile:
   ```bash
   export CODESIGN_IDENTITY="Developer ID Application: ..."
   export NOTARY_PROFILE="menutools-notary"
   ```
3. Generate Sparkle Ed25519 keys. Keep the private key in local or CI secret storage and export:
   ```bash
   export SPARKLE_PUBLIC_ED_KEY="..."
   export SPARKLE_PRIVATE_ED_KEY_FILE="/secure/path/sparkle_ed25519_private_key"
   ```
4. Run `./release.sh` to execute tests, build, embed and sign Sparkle, package ZIP/DMG, notarize, staple, and generate the appcast.
5. Create a GitHub Release with a tag such as `v1.0.4` and attach the generated `.zip` and `.dmg` files.
6. Upload `dist/appcast.xml` to the GitHub Release as `appcast.xml` (the current `SUFeedURL` points to `releases/latest/download/appcast.xml`).

The default feed is configured by `SUFeedURL` in `Resources/Info.plist`. Override the download URL prefix for another hosting service:

```bash
export SPARKLE_DOWNLOAD_URL_PREFIX="https://your-server/releases/"
```

## Known Limitations

- Night Shift and classic Bluetooth headset battery levels depend on private system APIs. They may stop working after a major macOS update; capability checks make the app fail gracefully when the APIs are unavailable. Validation scripts are included in `Scripts/`.
- Bluetooth devices that do not report battery levels cannot be displayed with a percentage.
- AirPods case battery levels may only be reported when the case is open or the device has just connected.
- Per-app volume requires System Audio Recording permission. DRM-protected or otherwise untappable audio keeps its original system volume.
- Empty Trash and screenshot actions depend on macOS Automation and Screen Recording permissions; denied access is reported in the panel.
- Shortcut conflict detection covers system hotkeys and exclusive Carbon hotkeys registered by other apps; apps using private event taps cannot be fully enumerated through public APIs.

## Acknowledgements

The smooth-scrolling design was inspired by the technical approach of [Mos](https://github.com/Caldis/Mos), including event templates, frame-based interpolation, peak filtering, buffer/current easing, and modifier-key controls. MenuTools is an independent implementation and does not copy Mos source code. Mos is licensed under [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/), which is not compatible with this project's MIT license; it is credited here as a source of technical inspiration only.

## License

[MIT](LICENSE)
