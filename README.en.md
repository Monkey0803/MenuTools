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
| System output volume | Controls the current default output device, stays synchronized with system mute, supports a volume cap and automatic headphone limiting. |
| Per-app volume | Independently adjusts active apps from 0–150% (with boost); muting remembers the last non-zero level. |
| Per-app EQ | 9-band equalizer (±12 dB), 10 built-in presets, plus a reusable custom-curve preset library. |
| Balance and mono | Per-app left/right balance (unity at the center) and multi-channel mono downmix. |
| Output device | Routes a single app to a specific output device and remembers master volume per device. |
| Presets and profiles | Remembers levels by root app bundle ID (helpers merged into the parent app); presets capture EQ, output device, group, favorites and channel settings together. |
| Automation | Applies presets by output device, time range, Focus mode, frontmost app or Wi-Fi name, with a one-step undo. |
| Meeting ducking | Lowers other apps while meeting audio plays and restores them afterwards. |
| Input volume | Microphone level and mute, live metering, and a pre-meeting audio check. |
| Session management | Search, groups (browser/meeting/game/other), sorting, favorites, and bulk mute or restore for the current list. |
| Shortcuts and HUD | Panel shortcut, master volume ±, system mute, a volume HUD, and a menu bar title showing master volume or the loudest app. |
| Diagnostics | Sampling cost, routing failure reasons and DRM / Process Tap notes, copyable as a report. |

### Productivity Tools

| Feature | Description |
|---|---|
| App Launcher | Search and launch installed apps, with favorites and recent-app ordering. |
| Scenes | Apply Work, Presentation, or Night presets manually. |
| Window Management | Use 60 layouts, including Loop-style edge stashing, with edge snapping, drop previews (plus haptics and a grow-in animation), optional finer snap areas with per-area custom actions; dragging a snapped window out restores its previous size; repeat a shortcut to cycle through layouts of the same family or to send the window to the adjacent display; save named presets that store a fixed window size, bind them to global shortcuts, and apply them from the quick-access panel; app rules with a window-title filter and a first/main-window limit, multi-window tiling, and per-app size memory included. |
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
| Clear clipboard | Shows the current clipboard item count, clears it with one click, and distinguishes "cleared" from "already empty". |
| Clipboard History | Keeps text, rich text, images, links, and files (including PDFs) with search, category/source/time filters, pinning, batch pin and sensitive marking, plain-text paste, and direct paste. |
| Clipboard Tools | Sequential paste queue, text transforms (case, join lines, URL encoding, JSON formatting), snippet templates such as `{{date}}` and `{{clipboard}}`, plus on-device OCR and QR recognition for images. |
| Clipboard Privacy | Pause recording, exclude apps, override recording and retention per bundle ID, and automatically hold back passwords, verification codes, card numbers, and custom keywords with a short expiry. |
| Clipboard Management | Automatic cleanup by item count, retention days, and storage size, plus passphrase-encrypted archive import/export (`.mtclip`) and shared-folder sync of pinned items and snippets, with an optional automatic interval, a keychain-stored passphrase, and last-sync/error status. |
| Clipboard Shortcut | A global shortcut opens the clipboard panel and falls back to a monitor listener when exclusive registration is unavailable. |
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

Current target release: [MenuTools v1.1.0](https://github.com/Monkey0803/MenuTools/releases/tag/v1.1.0)

Pick either package:

- `MenuTools-1.1.0.dmg`: open it and drag `MenuTools.app` into Applications
- `MenuTools-1.1.0.zip`: extract it and move `MenuTools.app` into Applications

Source archives (zip / tar.gz) are generated by GitHub for each tag. Every release note lists the SHA-256 of the downloadable files.

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

The script reports sample duration, process-row counts, non-zero traffic rows, and a final summary. Then cross-check the matching app, rate, and connection details in MenuTools Settings. For item-by-item manual verification use the [Network Traffic runtime acceptance checklist](docs/network-traffic-acceptance.md) (live rates, connection details, filters, history hover, menu bar speed, notification permission, quota alerts, redacted export, data clearing, and plugin ownership).

> Archived baseline: the 8-hour run on 2026-09-11 completed 2857/2857 samples with 0 failures, 72ms average and 133ms worst case.

### Clipboard Verification

Clipboard image recognition and auto-paste depend on system capabilities (Vision, Accessibility, CGEvent), so a standalone script covers them:

```bash
swift Scripts/test_clipboard_autopaste.swift                # pasteboard read/write, image and rich-text representations, Vision QR recognition
swift Scripts/test_clipboard_autopaste.swift --interactive   # adds the end-to-end ⌘V paste check (overwrites the system clipboard)
```

`--interactive` requires Accessibility permission and a focused editable field within 5 seconds of the prompt. The default non-interactive mode uses a private pasteboard only and leaves the system clipboard untouched.

### Window Management Verification

Window layouts, drag snapping, and stashing all depend on Accessibility APIs, so a standalone script covers them:

```bash
swift Scripts/test_window_management.swift                # read-only: permission, multi-display geometry, coordinate round-trip, AX attributes
swift Scripts/test_window_management.swift --interactive   # adds writes: move the focused window to the left half and restore it, and confirm AX accepts off-screen coordinates (stashing)
```

Drag snapping and the drop preview only run during a real drag, so turn on the diagnostic log when investigating:

```bash
touch /tmp/menutools-snap-debug     # from the next launch, writes /tmp/menutools-snap.log: hit test, title-bar check, preview target, snap on release
rm /tmp/menutools-snap-debug        # disable (nothing is logged by default)
```

Note: CGEvent-synthesized mouse events are not delivered to `NSEvent` global monitors on macOS 26, so drag behaviour cannot be scripted and has to be verified by hand. A step-by-step checklist lives in [`docs/window-management-acceptance.md`](docs/window-management-acceptance.md).

### Triggering Window Actions by URL

The menu-bar app has no window of its own, but `menutools://` links can trigger window actions from Raycast, Shortcuts, or scripts:

```bash
open "menutools://window?layout=left-half"     # apply a layout
open "menutools://action?name=maximize"        # matches Rectangle's execute-action naming
open "menutools://preset?name=开发"             # apply a fixed-size preset
```

Layout names use kebab-case derived from the layout itself (`left-half`, `top-left-sixth`, `stash-left`, …); all 60 layouts are available.

## Permissions

Some features request permissions the first time they are used:

| Permission | Purpose | Features |
|---|---|---|
| Automation → Finder | Reads the path of the frontmost Finder window. | Open Finder path in a terminal |
| Automation → Finder | Empties the Trash. | Quick Action Center |
| Automation → System Events | Changes appearance, Dock, and menu bar settings. | Appearance, Dock, and menu bar toggles |
| Bluetooth | Reads battery levels from connected Bluetooth devices. | Bluetooth battery levels |
| Notifications | Delivers high-traffic and monthly-quota alerts. | Network Traffic |
| Screen Recording | Allows screen capture. | Screenshot to Clipboard |
| Screen Recording | Allows window, area, and scrolling capture. | Screenshot Tools |
| System Audio Recording | Captures active app audio and replays it with an independent gain. | Per-app volume management |
| Accessibility | Reads and sets the position and size of the frontmost window. | Window Management |
| Accessibility | Receives global keyboard events and triggers scenes. | Global scene shortcuts, Focus |
| Accessibility | Synthesizes ⌘V to paste back into the previous app. | Clipboard auto-paste |

If permission was denied, enable it again in **System Settings → Privacy & Security**. If notifications were denied, allow them again under **System Settings → Notifications → MenuTools**; the Network Traffic settings page shows the current authorization state and links straight to System Settings when it is denied. Mute, prevent sleep, Night Shift, clipboard history recording, and cleanup features do not require these permissions (clipboard auto-paste does).

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
| Clipboard History | One-second `NSPasteboard` polling, SQLite metadata with binary blobs stored separately (schema version guard and migration), passphrase-encrypted archives, scheduled shared-folder sync with a keychain passphrase, Vision OCR/QR recognition behind a process-wide gate with retry and a manual retry action, and synthesized ⌘V paste via CGEvent |
| App Volume Management | Public Core Audio Process Tap, a private aggregate device, and IOProc routing; routes only apps below 100% and destroys taps to restore original audio on exit or failure |
| Network Status | CoreWLAN, interface addresses, VPN state, and on-demand URLSession probes |
| Network Traffic | `/usr/bin/nettop` process sampling, SQLite/WAL history, diagnostics, quota alerts, and optional redacted exports |
| Battery Health | `system_profiler SPPowerDataType -json`, with silent fallback when unavailable |
| Displays | `NSScreen` and CoreGraphics display mode enumeration and switching |
| Storage Analysis | Background recursive measurement of selected directories; cleanup keeps directories and never touches Downloads |
| App Launcher | NSWorkspace app discovery, search, favorites, and launching |
| Scenes | Composes app launching, appearance, Focus, audio, desktop icons, and prevent-sleep actions |
| Window Management | Accessibility API for window position, size, and display movement; global NSEvent drag monitoring drives edge snapping and target-frame previews; layout cycling, per-app frame memory, presets, and app rules are persisted; the settings pane and quick-access panel group layouts by family and offer search |
| Focus | Control Center accessibility script with a System Settings fallback |
| Global shortcuts | NSEvent global/local keyboard monitors, persistent bindings, and conflict detection |
| Update checks | Sparkle standard updater with Ed25519-signed appcast |

Project structure:

```text
MenuTools/
├── Package.swift               # Swift Package Manager manifest
├── build.sh                    # Build, package, and sign script
├── release.sh                  # Release checks and packaging (github self-signed / developer-id notarized)
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

1. Write this release's user-facing changes into `Resources/ReleaseNotes.md` (add a section titled like `## 1.1.2 — 2026-09-20`) — the same text feeds the in-app "Settings → Release notes"; `release.sh` refuses to run when the current version has no section.
2. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, commit, and make sure the working tree is clean (the script enforces this).
3. Choose a release mode:

   **GitHub open-source distribution (default, self-signed)**
   ```bash
   ./release.sh          # same as RELEASE_MODE=github
   ```
   The script runs tests, produces a release build signed with `MenuTools Self-Signed`, packages ZIP and DMG, generates an Ed25519-signed `dist/appcast.xml`, and prints the SHA-256 of all three assets. The private key defaults to `.cert/sparkle_ed25519_private_key` (that directory is gitignored).

   **Developer ID distribution (requires Apple Developer credentials)**
   ```bash
   export CODESIGN_IDENTITY="Developer ID Application: ..."
   export NOTARY_PROFILE="menutools-notary"
   export SPARKLE_PUBLIC_ED_KEY="..."
   export SPARKLE_PRIVATE_ED_KEY_FILE="/secure/path/sparkle_ed25519_private_key"
   RELEASE_MODE=developer-id ./release.sh
   ```
   This path additionally notarizes, staples, and runs `spctl`; it cannot be used without a Developer ID certificate.
4. The script generates `docs/release-notes-<version>.md`: the "what's new" section comes from `Resources/ReleaseNotes.md`, and the SHA-256 values of all three assets are filled in automatically. Extra verification bullets go into `docs/release-verification-<version>.md`, which is merged into the verification section. To regenerate the file after editing copy only:
   ```bash
   RELEASE_NOTES_ONLY=1 ./release.sh                          # reuse the recorded test count
   RELEASE_NOTES_ONLY=1 RELEASE_TEST_COUNT=582 ./release.sh   # set the test count explicitly
   ```
5. Publish with the generated notes:
   ```bash
   gh release create v1.1.2 \
     dist/MenuTools-1.1.2.zip dist/MenuTools-1.1.2.dmg dist/appcast.xml \
     --title "MenuTools 1.1.2" \
     --notes-file docs/release-notes-1.1.2.md \
     --target main
   ```
   Keep `appcast.xml` under that exact filename (`SUFeedURL` points to `releases/latest/download/appcast.xml`), otherwise clients never see the update. Source archives are generated by GitHub for each tag.

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
- Clipboard history works by polling the system pasteboard, so it only records what has already been copied. macOS does not expose the copy source, so "excluded apps" are judged by the frontmost app at copy time.
- Image text recognition relies on on-device Vision and may briefly return empty results under heavy system load; failures are retried automatically and again when the clipboard panel is reopened.
- Shared-folder sync covers "pinned items + snippets": deleting a pinned item, snippet, or group propagates as a deletion to other devices (tombstones are kept for 30 days), and snippets move to the default group when their group is deleted
- Pin state, titles/tags/notes, snippet renames, and favorites all merge in favour of the newer edit, so unpinning propagates too. Automatic image recognition is a derived result and never outranks your edits on another device
- When another device writes the shared file at the same time, sync re-merges with the new content (up to 3 attempts); persistent contention writes a `MenuTools-Clipboard.conflict-<timestamp>.mtclipsync` copy and points you at it from Settings.
- Window Management needs Accessibility permission; without it layout shortcuts and edge snapping do nothing, and the settings pane shows a warning instead.
- Drag snapping triggers when the cursor enters the snap band or when the dragged window's edge is already pressed against the screen edge: when you grab the middle of a title bar the window reaches the edge long before the cursor does, and both signals count.
- Finer snap areas (Rectangle style) are off by default: enabling them makes the top edge maximize, the bottom edge split into thirds, and moves the top/bottom halves onto the upper/lower third of the left and right edges.
- App-rule title filters only apply to automatic rule application; dialogs, system dialogs, and sheets are skipped.
- Each snap area's action can be remapped to any layout (Settings → Snap area actions); resetting restores the built-in actions for every area. Zones unique to the detailed model (bottom thirds, upper/lower thirds of the side edges) keep their built-in actions.
- The "first/main window only" app-rule limit falls back to "is the main window" when the main window cannot be read, so the rule never silently stops working.
- Full-screen windows are excluded from multi-window tiling and are never a drag-snapping target.
- Some apps enforce a minimum window size, so very small layouts (such as a sixth of the screen) may leave the window larger than requested.
- Fixed-size presets store only a position and size, not a specific display; when applied after a display change they are clamped back into the current display's usable area.
- Repeating a half-screen shortcut to reach the adjacent display requires at least two displays and is off by default; enable it in Settings.
- Stashing (pushing a window mostly off-screen at an edge) relies on apps accepting off-screen positions; a few apps clamp the window back on screen, in which case stashing has no effect (`Scripts/test_window_management.swift --interactive` covers this capability).
- Network Traffic samples processes through the system `/usr/bin/nettop`, so bytes are aggregated per process/app and cannot be split across remote destinations (connection details only cover the current connections and endpoints). Interface filtering uses nettop interface classes (external, wifi, wired, awdl, expensive, loopback), not physical device names, and VPN (utun) tunnels are not listed separately.
- History charts, rankings, and today/month totals come from samples accumulated on this Mac: a fresh install has no history until the module has been running for a while. If a major macOS upgrade changes nettop output fields, run `Scripts/test_network_traffic.swift` to validate.
- High-traffic and monthly-quota alerts require notification permission; when notifications are denied the alerts are silently dropped, and the Network Traffic settings page shows the state with a button that opens System Settings.

## Acknowledgements

The smooth-scrolling design was inspired by the technical approach of [Mos](https://github.com/Caldis/Mos), including event templates, frame-based interpolation, peak filtering, buffer/current easing, and modifier-key controls. MenuTools is an independent implementation and does not copy Mos source code. Mos is licensed under [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/), which is not compatible with this project's MIT license; it is credited here as a source of technical inspiration only.

## License

[MIT](LICENSE)
