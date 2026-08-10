# In-App Update Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Download GitHub Release update packages inside MenuTools on the `1.0.2` branch and let the user open the downloaded installer.

**Architecture:** Keep release discovery in `UpdateCheckerService`. Add a small, injectable download service that owns download state and temporary-file handling. The menu panel and settings page call the same service-facing actions and never execute shell commands or replace the running app.

**Tech Stack:** Swift 6, SwiftUI, Foundation URLSession, AppKit NSWorkspace, Swift Testing, macOS 26.

## Global Constraints

- Download only valid `.zip`, `.dmg`, or `.pkg` assets from the discovered update URL.
- Do not replace the running app, request privilege escalation, or execute downloaded content.
- Keep network and filesystem boundaries injectable for deterministic tests.
- UI copy and code comments use Chinese; user-facing strings are localized in all five languages.
- Preserve existing update checking, backup/restore, and unrelated settings behavior.

---

### Task 1: Add Download State and Service Boundaries

**Files:**
- Create: `Sources/MenuTools/UpdateDownloadService.swift`
- Test: `Tests/MenuToolsTests/UpdateDownloadServiceTests.swift`

**Interfaces:**
- `enum UpdateDownloadState: Equatable, Sendable`
- `enum UpdateDownloadError: Error, Equatable`
- `protocol UpdatePackageDownloading`
- `protocol UpdatePackageOpening`
- `@MainActor final class UpdateDownloadService`

- [ ] **Step 1: Write failing state and validation tests**

Cover idle-to-downloading transitions, duplicate-start rejection, supported extensions, invalid URL rejection, cancellation, success, and failure state transitions.

- [ ] **Step 2: Run focused tests and confirm RED**

Run: `swift test --filter UpdateDownloadServiceTests`

Expected: FAIL because the state/service types do not exist.

- [ ] **Step 3: Implement the minimal service**

Keep the service on the main actor, inject downloader/opener protocols, and expose `state`, `start(update:)`, and `cancel()`. Store downloaded files under a unique `FileManager.default.temporaryDirectory` child; do not write to the app bundle.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run: `swift test --filter UpdateDownloadServiceTests`

Expected: all service tests pass.

### Task 2: Implement URLSession Download Adapter

**Files:**
- Modify: `Sources/MenuTools/UpdateDownloadService.swift`
- Test: `Tests/MenuToolsTests/UpdateDownloadServiceTests.swift`

**Interfaces:**
- Production downloader uses `URLSessionDownloadDelegate` or an equivalent async adapter to report progress and move the temporary file atomically.
- Production opener uses `NSWorkspace.shared.open(_:)` on the main actor.

- [ ] **Step 1: Add adapter tests for response and file errors**

Use injected fakes to prove non-2xx responses, unsupported extensions, read/move failures, and cancellation become explicit service states without invoking AppKit.

- [ ] **Step 2: Implement URL validation and response checks**

Require a valid URL and successful HTTP response before marking download complete. Preserve the original download error for localized mapping while not exposing raw paths or response bodies.

- [ ] **Step 3: Implement progress and temporary-file finalization**

Report `0...1` progress, move the finished file to a unique temporary destination with an extension preserved from the source URL, and transition to completed only after the move succeeds.

- [ ] **Step 4: Run focused tests**

Run: `swift test --filter UpdateDownloadServiceTests`

Expected: all download adapter tests pass.

### Task 3: Connect Menu Panel and Settings UI

**Files:**
- Modify: `Sources/MenuTools/MenuPanelView.swift`
- Modify: `Sources/MenuTools/SettingsView.swift`
- Modify: `Resources/en.lproj/Localizable.strings`
- Modify: `Resources/ja.lproj/Localizable.strings`
- Modify: `Resources/ko.lproj/Localizable.strings`
- Modify: `Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Resources/zh-Hant.lproj/Localizable.strings`

**Interfaces:**
- Both views use the same `UpdateDownloadService` behavior and map state to localized labels/status.
- Existing “open download page” actions become “download update” actions.

- [ ] **Step 1: Add localized download strings**

Add labels for downloading, progress, cancel, completed/open, unsupported package, download failure, and open failure in all five localizations.

- [ ] **Step 2: Add service state to the menu panel**

Show progress while downloading, disable repeated update actions, provide cancel behavior, and present a confirmation before opening the completed package.

- [ ] **Step 3: Add service state to the settings page**

Use the same download flow from the manual update result, including progress, cancellation, completion confirmation, and localized failure status.

- [ ] **Step 4: Run all tests**

Run: `swift test`

Expected: all tests pass.

### Task 4: Package and Verify

**Files:**
- Modify: `Resources/Info.plist:29-32`

- [ ] **Step 1: Set the 1.0.2 app version**

Set `CFBundleShortVersionString` and `CFBundleVersion` to `1.0.2`.

- [ ] **Step 2: Run full verification**

Run:

```bash
swift test
swift build -c release
./build.sh
```

Expected: all tests pass and `dist/MenuTools.app` is assembled successfully.

- [ ] **Step 3: Verify update references and branch**

Run: `rg -n "UpdateDownload|download update|下载更新|NSWorkspace|temporaryDirectory" Sources Tests Resources` and `git branch --show-current`.

Expected: references are limited to the new download feature, and the branch is `1.0.2`.
