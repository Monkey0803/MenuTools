# 快捷键绑定可靠性修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让快捷键设置页只显示实际注册成功的绑定，并为注册失败、辅助功能权限不足和录制器生命周期提供明确处理。

**Architecture:** 把“绑定字典的冲突检查和提交时机”提取为无系统依赖的 `ShortcutBindingState`，用 Swift Testing 做纯逻辑回归。`ShortcutManager` 继续是 Carbon 唯一入口，负责注册、注销、失败回滚和错误状态；`ShortcutSettingsView` 只观察管理器状态并展示提示。`ShortcutAction` 在合成按键入口做权限防护并返回执行结果。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Carbon HIToolbox、CoreGraphics、Swift Testing、Swift Package Manager。

## Global Constraints

- 项目要求 macOS 26+ / Swift 6。
- UI 文案与代码注释使用中文。
- 所有手工文件修改使用 `apply_patch`。
- 不改变九个现有快捷键动作的持久化 key 和 JSON 结构。
- 不重写听写、勿扰模式和显示桌面的底层系统方案；空间切换使用 macOS 标准的 System Events `Control+方向键`，避免 SkyLight 私有 API 引起窗口合成异常。
- 不修改当前工作区中与快捷键无关的未提交文件，不创建 Git 提交。

---

### Task 1: 建立可测试的绑定状态层

**Files:**
- Create: `Sources/MenuTools/ShortcutBindingState.swift`
- Create: `Tests/MenuToolsTests/ShortcutBindingStateTests.swift`
- Modify: `Package.swift:9-13`

**Interfaces:**
- Produces `ShortcutBindingState.Update`，供 `ShortcutManager` 使用。
- `ShortcutBindingState` 不依赖 AppKit、Carbon 或 `ShortcutAction`，动作通过 `String` key 标识。

- [ ] **Step 1: 写失败测试，覆盖冲突、注册失败不提交、成功提交和清除**

```swift
import Carbon.HIToolbox
import Testing
@testable import MenuTools

@Test("重复组合键被拒绝且原绑定不变")
func duplicateComboIsRejected() {
    let first = KeyCombo(keyCode: 1, modifiers: cmdKey, display: "⌘A")
    var state = ShortcutBindingState(bindings: ["missionControl": first])

    let result = state.update(actionKey: "launchpad", combo: first) { _ in true }

    #expect(result == .conflict("missionControl"))
    #expect(state.bindings == ["missionControl": first])
}

@Test("注册失败时不提交新绑定")
func failedRegistrationDoesNotCommit() {
    let old = KeyCombo(keyCode: 1, modifiers: cmdKey, display: "⌘A")
    let replacement = KeyCombo(keyCode: 2, modifiers: cmdKey, display: "⌘B")
    var state = ShortcutBindingState(bindings: ["missionControl": old])

    let result = state.update(actionKey: "missionControl", combo: replacement) { _ in false }

    #expect(result == .registrationFailed)
    #expect(state.bindings["missionControl"] == old)
}

@Test("注册成功后才提交新绑定")
func successfulRegistrationCommits() {
    let combo = KeyCombo(keyCode: 1, modifiers: cmdKey, display: "⌘A")
    var state = ShortcutBindingState()

    let result = state.update(actionKey: "missionControl", combo: combo) { _ in true }

    #expect(result == .updated)
    #expect(state.bindings["missionControl"] == combo)
}

@Test("清除绑定不调用注册器并删除状态")
func clearingRemovesBinding() {
    let combo = KeyCombo(keyCode: 1, modifiers: cmdKey, display: "⌘A")
    var state = ShortcutBindingState(bindings: ["missionControl": combo])
    var registrationCalled = false

    let result = state.update(actionKey: "missionControl", combo: nil) { _ in
        registrationCalled = true
        return true
    }

    #expect(result == .updated)
    #expect(state.bindings.isEmpty)
    #expect(!registrationCalled)
}
```

- [ ] **Step 2: 添加测试 target 并运行测试确认测试因类型尚不存在而失败**

在 `Package.swift` 的 `targets` 中保留现有 executable target，并追加：

```swift
.testTarget(
    name: "MenuToolsTests",
    dependencies: ["MenuTools"],
    path: "Tests/MenuToolsTests"
)
```

运行：`swift test --filter MenuToolsTests`  
预期：FAIL，原因是 `ShortcutBindingState` 尚未定义。

- [ ] **Step 3: 实现最小状态层**

```swift
struct ShortcutBindingState {
    enum Update: Equatable {
        case updated
        case conflict(String)
        case registrationFailed
    }

    private(set) var bindings: [String: KeyCombo]

    init(bindings: [String: KeyCombo] = [:]) {
        self.bindings = bindings
    }

    mutating func update(
        actionKey: String,
        combo: KeyCombo?,
        register: (KeyCombo) -> Bool
    ) -> Update {
        if let combo {
            if let owner = bindings.first(where: {
                $0.key != actionKey && $0.value == combo
            })?.key {
                return .conflict(owner)
            }
            guard register(combo) else { return .registrationFailed }
            bindings[actionKey] = combo
        } else {
            bindings.removeValue(forKey: actionKey)
        }
        return .updated
    }
}
```

`ShortcutBindingState.swift` 需要导入 `Foundation` 以使用现有 `KeyCombo` 的 Codable 类型；不要复制 `KeyCombo` 定义。

- [ ] **Step 4: 运行测试确认通过**

运行：`swift test --filter MenuToolsTests`  
预期：4 个测试通过。

---

### Task 2: 加固 Carbon 注册和失败回滚

**Files:**
- Modify: `Sources/MenuTools/ShortcutManager.swift:7-107`
- Modify: `Sources/MenuTools/ShortcutBindingState.swift`

**Interfaces:**
- `ShortcutManager.lastError: ShortcutManagerError?` 为 `@Published private(set)`，供设置页观察。
- `ShortcutManager.setCombo(_:for:)` 保持现有调用签名。
- `ShortcutManager.handleHotKey(id:)` 根据 `ShortcutPerformResult` 更新错误状态。

- [ ] **Step 1: 运行纯逻辑回归基线**

测试只覆盖 `ShortcutBindingState` 的纯逻辑；Carbon `EventHotKeyRef` 不在单元测试中伪造。运行：`swift test --filter MenuToolsTests`，确认 Task 1 的 4 个测试通过后再修改管理器。

- [ ] **Step 2: 实现结构化错误状态**

在 `ShortcutManager.swift` 中增加：

```swift
enum ShortcutManagerError: Equatable, Identifiable {
    case eventHandlerUnavailable
    case duplicate(ShortcutAction)
    case registrationFailed(ShortcutAction)
    case restorationFailed(ShortcutAction)
    case accessibilityRequired
    case actionUnavailable(ShortcutAction)

    var id: String { String(describing: self) }
}
```

增加：

```swift
@Published private(set) var lastError: ShortcutManagerError?
```

- [ ] **Step 3: 让事件处理器只在 `InstallEventHandler` 成功后标记已安装**

`installHandlerIfNeeded()` 改为返回 `Bool`。调用 `InstallEventHandler` 后检查 `OSStatus == noErr`；失败时设置 `.eventHandlerUnavailable` 并保持 `handlerInstalled == false`。事件回调读取 `EventHotKeyID` 时检查 `GetEventParameter` 返回值，失败直接返回 `eventNotHandledErr`。

- [ ] **Step 4: 让热键注册返回成功状态**

`registerHotKey` 改为 `@discardableResult private func registerHotKey(...) -> Bool`。只有 `RegisterEventHotKey` 返回 `noErr` 且 `EventHotKeyRef` 非空时，才写入 `hotKeyRefs` 和 `idToAction`。

- [ ] **Step 5: 用状态层实现冲突检查、成功提交和旧绑定恢复**

`setCombo` 使用以下顺序：

1. 清除当前错误。
2. 对非空组合检查 `ShortcutBindingState` 的冲突；冲突时不注销旧热键，设置 `.duplicate(ownerAction)`。
3. 保存旧组合，注销当前动作旧热键。
4. 调用 `registerHotKey`；成功后更新 `bindings`、同步状态并 `persist()`。
5. 失败时尝试重新注册旧组合；恢复成功则保留旧 `bindings`，恢复失败则移除运行时注册并设置 `.restorationFailed`。
6. 清除操作注销并删除字典项，持久化并清除错误。

`activate()` 按 `ShortcutAction.allCases` 的固定顺序注册持久化绑定，避免字典遍历顺序导致冲突结果不稳定。某个持久化组合注册失败时，从显示字典删除该组合并记录 `.registrationFailed`，最后只持久化成功注册的绑定。

- [ ] **Step 6: 运行测试和构建**

运行：`swift test --filter MenuToolsTests`  
预期：4 个纯逻辑测试通过。

运行：`swift build -c release`  
预期：Build complete，无 Swift 6 编译错误。

---

### Task 3: 加入动作失败结果和辅助功能状态

**Files:**
- Modify: `Sources/MenuTools/ShortcutAction.swift:33-117`
- Modify: `Sources/MenuTools/ShortcutManager.swift:99-101`
- Modify: `Sources/MenuTools/ShortcutSettingsView.swift:1-106`
- Modify: `Resources/*/Localizable.strings` 在快捷键文案附近追加错误和权限文案

**Interfaces:**
- `ShortcutPerformResult`：`.success`、`.needsAccessibility`、`.unavailable`。
- `ShortcutAction.perform() -> ShortcutPerformResult`。
- `ShortcutSettingsView` 观察 `manager.lastError` 和本地 `accessibilityOK`。

- [ ] **Step 1: 添加动作结果测试用的纯权限边界说明**

由于 `CGEvent`、TCC 和 `NSWorkspace` 依赖真实 macOS 环境，本任务不伪造系统事件测试。先运行 `swift test --filter MenuToolsTests`，以 Task 1 的纯逻辑测试作为回归基线。

- [ ] **Step 2: 增加动作结果类型并在合成按键前检查辅助功能**

在 `ShortcutAction.swift` 中增加：

```swift
enum ShortcutPerformResult {
    case success
    case needsAccessibility
    case unavailable
}
```

将 `perform()` 改为返回 `ShortcutPerformResult`。Spotlight、听写、勿扰、显示桌面、退出应用和空间切换的合成按键入口在调用 `KeySimulator.post` 前执行 `AXIsProcessTrusted()` 检查；权限不足返回 `.needsAccessibility`。`KeySimulator.post` 也保留防御性权限检查并返回 `Bool`，避免未来新增调用点绕过权限判断。

`launchFirstAvailable` 返回是否找到并发起了系统 App；路径全部不存在时返回 `.unavailable`。不把 `NSWorkspace.openApplication` 的异步完成结果误报为可验证成功。

- [ ] **Step 3: 在 `ShortcutManager.handleHotKey` 映射结果到错误状态**

```swift
private func handleHotKey(id: UInt32) {
    guard let action = idToAction[id] else { return }
    switch action.perform() {
    case .success:
        lastError = nil
    case .needsAccessibility:
        lastError = .accessibilityRequired
    case .unavailable:
        lastError = .actionUnavailable(action)
    }
}
```

- [ ] **Step 4: 在设置页增加权限提示、错误提示和跳转按钮**

增加 `@State private var accessibilityOK = AXIsProcessTrusted()` 和 2 秒主线程 timer，按 `ScrollSettingsView` 的现有实现刷新。权限不足时在 header 与列表之间显示提示卡，并用 `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` 打开系统设置。

错误提示通过 `manager.lastError` 映射本地化 key。成功设置或清除后由管理器清除错误；错误卡不直接修改绑定。

- [ ] **Step 5: 补无障碍标签并验证本地化键**

为清除按钮添加 `.accessibilityLabel(L("sc.clear"))`，为权限按钮提供可读标题和提示。五份本地化文件都追加同一组 key：权限提示、打开辅助功能、注册失败、重复绑定、动作不可用、事件处理器失败。

- [ ] **Step 6: 运行构建和 plist 检查**

运行：`swift build -c release`。  
运行：`plutil -lint Resources/Info.plist Resources/MenuTools.entitlements Extension/Info.plist Extension/RightClickTools.entitlements`。  
预期：构建完成，四个 plist 均输出 `OK`。

---

### Task 4: 修复录制器生命周期并完成回归审查

**Files:**
- Modify: `Sources/MenuTools/ShortcutSettingsView.swift:109-149`
- Modify: `Sources/MenuTools/ShortcutBindingState.swift`（仅在测试暴露出问题时）

**Interfaces:**
- `KeyRecorder.dismantleNSView` 显式停止 coordinator 监听。
- `Coordinator.stopMonitoring()` 保持幂等。

- [ ] **Step 1: 为 `NSViewRepresentable` 增加显式拆除入口**

```swift
static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stopMonitoring()
}
```

保持 `startMonitoring()` 的 `guard monitor == nil`，保持 `stopMonitoring()` 删除 monitor 后置空；不引入全局 monitor 或额外线程。

- [ ] **Step 2: 运行完整回归命令**

运行：`swift test`。  
预期：所有测试通过。

运行：`swift build -c release`。  
预期：Build complete。

运行：`git diff --check`。  
预期：无输出。

- [ ] **Step 3: 做实机验证清单**

人工验证以下路径：

- 绑定一个正常组合，重启应用后仍可触发。
- 给两个动作绑定同一组合，第二次操作显示冲突，第一项仍可用。
- 模拟或实际让 Carbon 注册失败，确认旧绑定未丢失且界面不显示失败组合。
- 未授权辅助功能时触发 Spotlight/显示桌面，设置页显示授权提示而非静默失败。
- 录制过程中切换 Tab、切换语言、关闭设置窗口，重新打开后按键不会修改旧动作。
- 清除按钮可被 VoiceOver 识别为“清除”。

听写双 Fn、勿扰模式映射、显示桌面和 SkyLight 空间切换仍记录为 macOS 26 实机行为风险，不因本次保护性修复标记为完全验证。
