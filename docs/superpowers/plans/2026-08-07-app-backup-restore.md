# App Backup and Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe JSON export/import for MenuTools user configuration on the `1.0.1` branch.

**Architecture:** Keep the backup document as a pure Codable model with validation. Put persistence and rollback behind a small service that receives `UserDefaults` and file/config boundaries, then expose it through a small section in `GeneralSettingsView` using `NSSavePanel` and `NSOpenPanel`.

**Tech Stack:** Swift 6, SwiftUI, AppKit panels, Foundation Codable, Swift Testing, macOS 26.

## Global Constraints

- Use only an allowlisted set of MenuTools configuration keys.
- Do not back up update-check internals, permissions, caches, or system state.
- Validate a complete document before modifying existing configuration.
- Preserve the current Liquid Glass and grouped Form settings style.
- UI copy and code comments use Chinese; backup field names remain stable ASCII identifiers.
- Do not modify unrelated worktree changes.

---

### Task 1: Add Backup Document Model and Validation

**Files:**
- Create: `Sources/MenuTools/AppBackupDocument.swift`
- Test: `Tests/MenuToolsTests/AppBackupDocumentTests.swift`

**Interfaces:**
- `struct AppBackupDocument: Codable, Equatable, Sendable`
- `struct AppBackupSettings: Codable, Equatable, Sendable`
- `enum AppBackupValidationError: Error, Equatable`
- `AppBackupDocument.current(settings:rightClick:appVersion:createdAt:)`
- `AppBackupDocument.validated() throws -> AppBackupDocument`

- [ ] **Step 1: Write failing tests for round-trip and unsupported version**

Cover: a complete document round-trips through JSON, unsupported `formatVersion` throws, and out-of-range scroll values throw.

- [ ] **Step 2: Run the focused tests and confirm RED**

Run: `swift test --filter AppBackupDocumentTests`

Expected: FAIL because `AppBackupDocument` does not exist.

- [ ] **Step 3: Implement the Codable models**

Use explicit properties for all allowlisted `SettingsKey` values and `RightClickConfig`; do not encode arbitrary `UserDefaults` dictionaries. Set `formatVersion` to `1` for new documents.

- [ ] **Step 4: Implement validation**

Reject unsupported format versions, invalid gain/duration/minimum-step values, and invalid modifier values. Preserve unknown JSON fields through normal Codable key omission behavior without executing them.

- [ ] **Step 5: Run focused tests and confirm GREEN**

Run: `swift test --filter AppBackupDocumentTests`

Expected: all document model tests pass.

### Task 2: Add Persistence and Rollback Service

**Files:**
- Create: `Sources/MenuTools/AppBackupService.swift`
- Modify: `Sources/MenuTools/RightClickConfig.swift`
- Test: `Tests/MenuToolsTests/AppBackupServiceTests.swift`

**Interfaces:**
- `protocol AppBackupFileAccessing`
- `struct LocalAppBackupFileAccess: AppBackupFileAccessing`
- `enum AppBackupService`
- `AppBackupService.makeDocument(userDefaults:rightClick:appVersion:createdAt:)`
- `AppBackupService.encode(_:encoder:) throws -> Data`
- `AppBackupService.decode(_:decoder:) throws -> AppBackupDocument`
- `AppBackupService.restore(_:userDefaults:rightClickStore:) throws`

- [ ] **Step 1: Write failing tests for encoding and safe restore**

Use isolated `UserDefaults` suites and an injected in-memory file/config boundary. Test successful restore, malformed data rejection without mutation, and right-click persistence failure rollback.

- [ ] **Step 2: Run focused tests and confirm RED**

Run: `swift test --filter AppBackupServiceTests`

Expected: FAIL because the service and file boundary do not exist.

- [ ] **Step 3: Add explicit RightClickConfig replacement support**

Expose a small validated persistence operation for the service without broadening `RightClickConfigStore` into a generic file system abstraction.

- [ ] **Step 4: Implement document creation, JSON encode/decode, and restore**

Read only the allowlisted settings. Validate before writes. Capture existing UserDefaults values and right-click configuration before restore; on any write failure, restore the captured values.

- [ ] **Step 5: Run focused tests and confirm GREEN**

Run: `swift test --filter AppBackupServiceTests`

Expected: all service tests pass.

### Task 3: Add Settings UI Export and Import

**Files:**
- Modify: `Sources/MenuTools/SettingsView.swift`
- Modify: `Resources/en.lproj/Localizable.strings`
- Modify: `Resources/ja.lproj/Localizable.strings`
- Modify: `Resources/ko.lproj/Localizable.strings`
- Modify: `Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Resources/zh-Hant.lproj/Localizable.strings`

**Interfaces:**
- `GeneralSettingsView` owns backup operation state and presents status text.
- `NSSavePanel` writes a `.menutoolsbackup` file selected by the user.
- `NSOpenPanel` selects one `.menutoolsbackup` file for restore.

- [ ] **Step 1: Add localized strings**

Add keys for the backup section title, export/import button labels, default filename, success messages, and invalid-file/write-failure errors in all five localizations.

- [ ] **Step 2: Add export action**

Present an `NSSavePanel` on the main actor, default to `MenuTools-1.0.1.menutoolsbackup`, encode the current document, and write atomically through `AppBackupService`.

- [ ] **Step 3: Add import action**

Present an `NSOpenPanel` restricted to `.menutoolsbackup`, read the selected file, validate and restore it, then reload the scroll engine and update the visible settings state.

- [ ] **Step 4: Add success and failure status**

Use a localized status message in the existing grouped Form style. Do not show raw decoding errors or filesystem paths as user-facing error text.

- [ ] **Step 5: Run all tests and build**

Run: `swift test`

Expected: all tests pass.

### Task 4: Package and Verify the Feature

**Files:**
- Modify: `Resources/Info.plist:29-32`
- No additional source files expected.

- [ ] **Step 1: Bump the app version for the 1.0.1 branch**

Set both `CFBundleShortVersionString` and `CFBundleVersion` to `1.0.1` so the app version, backup filename, and release metadata agree.

- [ ] **Step 2: Search for backup references and stale keys**

Run: `rg -n "AppBackup|menutoolsbackup|backup|restore" Sources Tests Resources`

Expected: references are limited to the new model, service, settings UI, tests, and localized strings.

- [ ] **Step 3: Run release build**

Run: `swift build -c release`

Expected: PASS under Swift 6 strict concurrency checks.

- [ ] **Step 4: Assemble the app**

Run: `./build.sh`

Expected: `dist/MenuTools.app` is assembled successfully.

- [ ] **Step 5: Verify the working tree and branch**

Run: `git status --short` and `git branch --show-current`

Expected: current branch is `1.0.1`; only intended feature files are modified.
