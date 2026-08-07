# Remove Shortcut Bindings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完全移除 MenuTools 的快捷键绑定功能及其运行时全局事件监听。

**Architecture:** 保留现有三类设置页面，仅从 `SettingsView` 移除快捷键页；`MenuToolsApp` 不再持有或启动快捷键相关状态和服务。快捷键专用实现、测试和本地化资源一并删除，其他服务不做重构。

**Tech Stack:** Swift 6、SwiftUI、Swift Package Manager、Swift Testing、macOS 26。

## Global Constraints

- 项目要求 macOS 26+ / Swift 6。
- UI 文案与代码注释使用中文。
- 使用 `apply_patch` 编辑文件。
- 不修改与快捷键无关的现有工作区变更。
- 不创建 Git 提交，除非用户明确要求。

---

### Task 1: Remove Settings and Startup Wiring

**Files:**
- Modify: `Sources/MenuTools/SettingsView.swift:9-47`
- Modify: `Sources/MenuTools/MenuToolsApp.swift:55-86,101-108`

**Interfaces:**
- `SettingsView` 保留无参数初始化和三个现有 Tab：`GeneralSettingsView`、`RightClickToolsView`、`ScrollSettingsView`。
- `MenuToolsApp` 保留 `SettingsView()` 场景和 `SmoothScrollEngine.shared.activateIfEnabled()`、`RightClickCommandHandler.activate()` 启动逻辑。

- [ ] **Step 1: Remove shortcut state and initializer parameters**

从 `SettingsView` 删除 `shortcutStore`、`shortcutMonitor`、`permissionService`、`permissionRecovery` 四个属性和自定义初始化器；删除 `ShortcutSettingsView` Tab，保留其他三个 Tab。

- [ ] **Step 2: Remove startup listener construction**

从 `MenuToolsApp` 删除快捷键四个属性、`init()` 中的权限服务、Store、Matcher、Monitor、PermissionRecovery 构造及启动代码；保留无参数 App 初始化和其他服务启动。

- [ ] **Step 3: Remove shortcut arguments from Settings scene**

将 `SettingsView(...)` 改为 `SettingsView()`。

- [ ] **Step 4: Build the focused target**

Run: `swift build`

Expected: PASS; if compilation reports a remaining shortcut reference, remove only that reference before continuing.

### Task 2: Delete Shortcut-Only Source and Tests

**Files:**
- Delete: `Sources/MenuTools/ShortcutAction.swift`
- Delete: `Sources/MenuTools/ShortcutActionCatalog.swift`
- Delete: `Sources/MenuTools/ShortcutActionExecutor.swift`
- Delete: `Sources/MenuTools/ShortcutBinding.swift`
- Delete: `Sources/MenuTools/ShortcutBindingMatcher.swift`
- Delete: `Sources/MenuTools/ShortcutBindingStore.swift`
- Delete: `Sources/MenuTools/ShortcutEventMonitor.swift`
- Delete: `Sources/MenuTools/ShortcutPermissionService.swift`
- Delete: `Sources/MenuTools/ShortcutSettingsView.swift`
- Delete: `Sources/MenuTools/ShortcutTrigger.swift`
- Delete: `Sources/MenuTools/ShortcutTriggerRecorder.swift`
- Delete: `Sources/MenuTools/OpenTargetPayload.swift`
- Delete: `Tests/MenuToolsTests/ShortcutActionTests.swift`
- Delete: `Tests/MenuToolsTests/ShortcutActionExecutorTests.swift`
- Delete: `Tests/MenuToolsTests/ShortcutBindingMatcherTests.swift`
- Delete: `Tests/MenuToolsTests/ShortcutEventMonitorTests.swift`
- Delete: `Tests/MenuToolsTests/ShortcutModelTests.swift`
- Delete: `Tests/MenuToolsTests/ShortcutSettingsStateTests.swift`

**Interfaces:**
- No replacement interfaces are introduced. `SpaceService.swift` remains because it is used outside the removed binding feature.

- [ ] **Step 1: Delete shortcut-only production files**

Delete the listed files with `apply_patch`; do not delete `SpaceService.swift` or unrelated system services.

- [ ] **Step 2: Delete shortcut-only tests**

Delete the listed test files; remaining tests must compile without importing any deleted type.

- [ ] **Step 3: Search for dangling references**

Run: `grep`/`rg` over `Sources`, `Tests`, and `Resources` for `Shortcut`, `shortcutBindings`, `settings.tab.shortcut`, and `sc.`.

Expected: no shortcut-binding-specific matches; “快捷开关” (`快捷开关`) matches are allowed.

### Task 3: Remove Shortcut Localization and Persisted Data

**Files:**
- Modify: `Resources/en.lproj/Localizable.strings:123-198`
- Modify: `Resources/ja.lproj/Localizable.strings:123-198`
- Modify: `Resources/ko.lproj/Localizable.strings:123-198`
- Modify: `Resources/zh-Hans.lproj/Localizable.strings:123-198`
- Modify: `Resources/zh-Hant.lproj/Localizable.strings:123-198`

**Interfaces:**
- No new localization keys.

- [ ] **Step 1: Remove shortcut localization blocks**

Delete the `/* Shortcut binding */` / equivalent comment and all `settings.tab.shortcut` and `sc.*` entries. Do not remove unrelated `settings.section.panel` or other `rc.*` entries.

- [ ] **Step 2: Clear persisted shortcut data**

Run:

```bash
defaults delete com.qoder.menutools shortcutBindingsV2
defaults delete com.qoder.menutools shortcutBindingsV2.corruptedBackup
defaults delete com.qoder.menutools shortcutBindings
```

Expected: keys absent; “domain/default pair does not exist” is acceptable for already absent keys.

### Task 4: Full Verification and App Packaging

**Files:**
- No source changes expected.
- Build output: `dist/MenuTools.app` (ignored artifact).

- [ ] **Step 1: Run all tests**

Run: `swift test`

Expected: all remaining tests pass.

- [ ] **Step 2: Run release build**

Run: `swift build -c release`

Expected: PASS with no deleted shortcut type references.

- [ ] **Step 3: Assemble and sign the app**

Run: `./build.sh`

Expected: `dist/MenuTools.app` is assembled and signed successfully.

- [ ] **Step 4: Verify runtime surface**

Run:

```bash
pkill -f MenuTools.app/Contents/MacOS/MenuTools || true
open dist/MenuTools.app
```

Verify the settings window has exactly three tabs and the persisted shortcut keys remain absent.
