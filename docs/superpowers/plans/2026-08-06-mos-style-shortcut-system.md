# Mos 风格通用快捷键系统 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用单一全局 `CGEventTap` 和 `TriggerEvent -> ShortcutAction` 数据模型替换 MenuTools 当前的 Carbon 单动作快捷键系统。

**Architecture:** 先建立无 AppKit/Carbon 副作用的数据模型、持久化和匹配器，再通过协议接入真实事件 tap、权限服务和动作执行器。最后重做设置页绑定列表，并删除旧 `RegisterEventHotKey` 管理器；所有系统依赖通过协议注入，纯逻辑和 Manager-facing 测试先于真实系统接入。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Carbon/CoreGraphics、NSAppleScript、Process、Swift Testing、Swift Package Manager。

## Global Constraints

- 项目要求 macOS 26+ / Swift 6。
- UI 文案与代码注释使用中文。
- 首版支持普通键、组合键、单独修饰键和 CGEvent 可见的鼠标按钮。
- 允许破坏性重置；不迁移旧 `shortcutBindings` 数据。
- 新持久化 key 必须为 `shortcutBindingsV2`。
- 不使用 `RegisterEventHotKey`，不调用 SkyLight 私有 API 切换空间。
- 空间切换使用 System Events 的 `Control+方向键`。
- 脚本动作使用 `Process` 参数数组，不拼接 shell 命令。
- 不支持 Logitech HID++ 专用协议、云同步、多步组合、双击触发或手势识别。
- 系统依赖失败不能静默删除绑定；权限不足时不能静默消费原事件。
- 所有手工文件修改使用 `apply_patch`；不创建 Git 提交。

---

### Task 1: 建立 TriggerEvent、Binding 和持久化模型

**Files:**
- Create: `Sources/MenuTools/ShortcutTrigger.swift`
- Create: `Sources/MenuTools/ShortcutBinding.swift`
- Create: `Sources/MenuTools/OpenTargetPayload.swift`
- Create: `Sources/MenuTools/ShortcutBindingStore.swift`
- Create: `Tests/MenuToolsTests/ShortcutModelTests.swift`
- Modify: `Package.swift:9-18`

**Interfaces:**
- Produces `TriggerEventType`, `DeviceFilter`, `TriggerEvent`, `ShortcutActionKind`, `ShortcutActionPayload`, `ShortcutBinding`, `ShortcutExecutionMode`, `OpenTargetPayload`, `ShortcutBindingStore`。
- Later tasks consume `TriggerEvent` as the stable event identity and `ShortcutBindingStore` as the only persistence boundary。

- [ ] **Step 1: 写失败测试，验证模型身份、冲突和 JSON round trip**

```swift
import Testing
@testable import MenuTools

@Test("显示文本不参与触发器身份")
func triggerIdentityIgnoresDisplayText() {
    let left = TriggerEvent(type: .keyboard, code: 123, modifiers: 2304, deviceFilter: nil)
    let same = TriggerEvent(type: .keyboard, code: 123, modifiers: 2304, deviceFilter: nil)

    #expect(left == same)
}

@Test("绑定模型可以保留结构化打开目标")
func bindingRoundTripsOpenTarget() throws {
    let target = OpenTargetPayload(
        path: "/Applications/Safari.app",
        bundleID: "com.apple.Safari",
        arguments: [],
        kind: .application
    )
    let binding = ShortcutBinding(
        trigger: TriggerEvent(type: .keyboard, code: 40, modifiers: 256, deviceFilter: nil),
        action: ShortcutActionPayload(kind: .openTarget, systemAction: nil, target: target)
    )
    let data = try JSONEncoder().encode(binding)
    let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: data)

    #expect(decoded == binding)
}

@Test("重复触发器被绑定状态拒绝")
func duplicateTriggersAreRejected() {
    let trigger = TriggerEvent(type: .mouse, code: 3, modifiers: 0, deviceFilter: nil)
    var store = ShortcutBindingStore(bindings: [
        ShortcutBinding(trigger: trigger, action: .system("showDesktop"))
    ])

    let result = store.add(ShortcutBinding(trigger: trigger, action: .system("spotlight")))

    #expect(result == .duplicate)
    #expect(store.bindings.count == 1)
}
```

- [ ] **Step 2: 添加 Swift Testing target 并运行 RED**

确保 `Package.swift` 包含：

```swift
.testTarget(
    name: "MenuToolsTests",
    dependencies: ["MenuTools"],
    path: "Tests/MenuToolsTests"
)
```

运行：`swift test --filter MenuToolsTests`  
预期：FAIL，原因是新模型类型尚未定义。

- [ ] **Step 3: 实现纯数据模型**

`TriggerEvent` 使用 `type/code/modifiers/deviceFilter` 作为 Codable 字段；不要增加 display 字段到身份模型。`ShortcutActionPayload` 提供工厂方法：

```swift
extension ShortcutActionPayload {
    static func system(_ rawValue: String) -> Self {
        Self(kind: .system, systemAction: rawValue, target: nil)
    }
}
```

模型同时定义：

```swift
struct DeviceFilter: Codable, Equatable, Hashable {
    let vendorID: UInt16?
    let productID: UInt16?
}

enum EventPhase: String, Codable, Equatable, Sendable {
    case down
    case up
}
```

`OpenTargetPayload` 的不变量：

- `.application` 才允许 `bundleID` 和 arguments
- `.script` 只允许参数数组，不允许 bundleID
- `.file` 强制清空 bundleID 和 arguments

`ShortcutBinding` 提供默认 `UUID`、`Date` 和 `.trigger` execution mode。

- [ ] **Step 4: 实现内存 BindingStore**

```swift
struct ShortcutBindingStore {
    enum UpdateResult: Equatable {
        case inserted
        case replaced
        case duplicate
        case removed
        case notFound
    }

    private(set) var bindings: [ShortcutBinding]

    init(bindings: [ShortcutBinding] = []) {
        self.bindings = bindings
    }

    mutating func add(_ binding: ShortcutBinding) -> UpdateResult
    mutating func replace(_ binding: ShortcutBinding) -> UpdateResult
    mutating func remove(id: UUID) -> UpdateResult
    mutating func setEnabled(id: UUID, enabled: Bool) -> Bool
}

`add` 在发现相同 `TriggerEvent` 时返回 `.duplicate`；`replace` 忽略自身 id 后执行同样冲突检查；`remove` 找不到 id 时返回 `.notFound`；`setEnabled` 找不到 id 时返回 `false`。
```

Store 的冲突比较只使用 `TriggerEvent` 的 Codable 字段，不比较展示字符串。

- [ ] **Step 5: 增加 UserDefaults 持久化边界**

`ShortcutBindingStore` 增加 `load(from:)` 和 `save(to:)`，固定 key 为 `shortcutBindingsV2`。保存顺序：先 JSON 编码成功，再写入 UserDefaults；编码失败时保留内存状态并返回错误。加载数组中单条无法解码的元素时跳过该条，其他条目继续加载。

首次加载新系统时删除旧 key：

```swift
userDefaults.removeObject(forKey: "shortcutBindings")
```

- [ ] **Step 6: 运行 GREEN 和严格并发构建**

运行：`swift test --filter MenuToolsTests`，预期模型测试通过。  
运行：`swift build -c release`，预期无 Swift 6 错误。

---

### Task 2: 实现纯事件快照和 BindingMatcher

**Files:**
- Create: `Sources/MenuTools/ShortcutBindingMatcher.swift`
- Create: `Tests/MenuToolsTests/ShortcutBindingMatcherTests.swift`

**Interfaces:**
- Produces `EventSnapshot`、`EventSnapshotType`、`BindingMatchResult`、`ShortcutBindingMatcher`。
- `EventSnapshot` 只包含 Sendable 值：`type/code/modifiers/phase`，不携带 `CGEvent`。

- [ ] **Step 1: 写失败测试，覆盖 Down/Up、修饰键和 active session**

```swift
@Test("按下匹配后释放事件不依赖释放时 modifier flags")
func activeBindingPairsDownAndUp() {
    let trigger = TriggerEvent(type: .keyboard, code: 40, modifiers: 256, deviceFilter: nil)
    let binding = ShortcutBinding(trigger: trigger, action: .system("showDesktop"), executionMode: .stateful)
    var matcher = ShortcutBindingMatcher(bindings: [binding])

    let down = EventSnapshot(type: .keyboard, code: 40, modifiers: 256, phase: .down)
    let up = EventSnapshot(type: .keyboard, code: 40, modifiers: 0, phase: .up)

    #expect(matcher.match(down) == .begin(binding))
    #expect(matcher.match(up) == .end(binding))
}

@Test("未匹配事件放行")
func unmatchedEventPassesThrough() {
    let matcher = ShortcutBindingMatcher(bindings: [])
    let event = EventSnapshot(type: .mouse, code: 3, modifiers: 0, phase: .down)

    #expect(matcher.match(event) == .passthrough)
}
```

- [ ] **Step 2: 运行 RED**

运行：`swift test --filter ShortcutBindingMatcherTests`。  
预期：FAIL，原因是 `EventSnapshot` 和 matcher 尚未定义。

- [ ] **Step 3: 实现快照和匹配器**

```swift
enum EventSnapshotType: String, Equatable, Sendable {
    case keyboard
    case modifier
    case mouse
}

struct EventSnapshot: Equatable, Sendable {
    let type: EventSnapshotType
    let code: UInt16
    let modifiers: UInt64
    let phase: EventPhase
}

enum ShortcutEventDecision: Equatable {
    case passthrough
    case consumed
}

enum ShortcutMonitorState: Equatable {
    case stopped
    case running(activeSessionCount: Int)

    mutating func stop() {
        self = .stopped
    }
}

enum BindingMatchResult: Equatable {
    case passthrough
    case begin(ShortcutBinding)
    case end(ShortcutBinding)
}
```

Matcher 维护 `[TriggerIdentity: ShortcutBinding]` 的 active 表；Down 只匹配启用绑定，Up 只从 active 表查找。`trigger.type == .modifier` 时只接受 flagsChanged 的按下阶段。

- [ ] **Step 4: 运行 GREEN**

运行：`swift test --filter ShortcutBindingMatcherTests`，预期所有匹配测试通过。  
运行：`swift test`，确认已有模型测试不回归。

---

### Task 3: 建立权限服务和动作执行器

**Files:**
- Create: `Sources/MenuTools/ShortcutPermissionService.swift`
- Create: `Sources/MenuTools/ShortcutActionCatalog.swift`
- Create: `Sources/MenuTools/ShortcutActionExecutor.swift`
- Modify: `Sources/MenuTools/ShortcutAction.swift`
- Modify: `Sources/MenuTools/SpaceService.swift`
- Create: `Tests/MenuToolsTests/ShortcutActionExecutorTests.swift`

**Interfaces:**
- `ShortcutPermissionProviding`: `accessibilityTrusted`, `automationTrusted`, `openAccessibilitySettings()`, `openAutomationSettings()`。
- `ShortcutActionExecuting`: `execute(_ action: ShortcutActionPayload) -> ShortcutExecutionResult`。
- `ShortcutActionCatalog`: 返回现有九个系统动作的标题、图标、权限需求和默认 execution mode。

- [ ] **Step 1: 写失败测试，覆盖权限、脚本参数和空间脚本**

```swift
@Test("脚本动作使用参数数组而不是 shell 拼接")
func scriptPayloadPreservesArguments() {
    let target = OpenTargetPayload(
        path: "/tmp/tool",
        bundleID: nil,
        arguments: ["--name", "hello"],
        kind: .script
    )

    #expect(target.arguments == ["--name", "hello"])
    #expect(target.bundleID == nil)
}

@Test("空间动作使用 Automation 权限边界")
func spaceActionRequiresAutomationWhenScriptFails() {
    let result = ShortcutExecutionResult.automationRequired
    #expect(result == .automationRequired)
}
```

- [ ] **Step 2: 运行 RED**

运行：`swift test --filter ShortcutActionExecutorTests`。  
预期：FAIL，原因是新的执行结果和权限协议尚未定义。

- [ ] **Step 3: 实现权限协议和 Action Catalog**

```swift
enum ShortcutExecutionResult: Equatable {
    case success
    case queued
    case accessibilityRequired
    case automationRequired
    case actionUnavailable
    case executionFailed(String)
}

protocol ShortcutActionExecuting {
    func execute(_ action: ShortcutActionPayload) -> ShortcutExecutionResult
}
```

系统动作目录保留现有九个 raw value；空间切换通过 `SpaceService` 生成 System Events 脚本；`OpenTargetPayload.application` 使用 NSWorkspace，`.script` 使用 `Process.executableURL` 和参数数组，`.file` 使用 NSWorkspace。

- [ ] **Step 4: 删除执行器对旧 Carbon Manager 的依赖**

将 `ShortcutAction.perform()` 的调用入口统一转移到 `ShortcutActionExecutor`。保留动作定义和 `ShortcutPerformResult` 的语义，但不再从 `ShortcutManager` 触发。

- [ ] **Step 5: 运行 GREEN**

运行：`swift test --filter ShortcutActionExecutorTests`。  
运行：`swift build -c release`。  
预期：执行器纯逻辑和现有项目均通过编译。

---

### Task 4: 实现全局 EventTap 和录制器

**Files:**
- Create: `Sources/MenuTools/ShortcutEventMonitor.swift`
- Create: `Sources/MenuTools/ShortcutTriggerRecorder.swift`
- Create: `Tests/MenuToolsTests/ShortcutEventMonitorTests.swift`

**Interfaces:**
- `ShortcutEventMonitoring`: `start()`, `stop()`, `isRunning`, `lastError`。
- `ShortcutEventMonitor` 接收 `ShortcutBindingMatcher`、`ShortcutActionExecuting` 和权限 provider。
- `ShortcutTriggerRecorder` 返回 `TriggerEvent`，支持 `.combination/.singleKey/.adaptive`。

- [ ] **Step 1: 写失败测试，覆盖事件 tap 状态和合成标记过滤**

```swift
@Test("合成事件标记会被放行，不会重新匹配")
func syntheticEventIsPassthrough() {
    let decision = ShortcutEventDecision.passthrough
    #expect(decision == .passthrough)
}

@Test("监听器停止后清空状态型绑定")
func stoppingMonitorClearsActiveSessions() {
    var state = ShortcutMonitorState.running(activeSessionCount: 1)
    state.stop()
    #expect(state == .stopped)
}
```

- [ ] **Step 2: 运行 RED**

运行：`swift test --filter ShortcutEventMonitorTests`。  
预期：FAIL，原因是新的 monitor 状态和决策类型尚未定义。

- [ ] **Step 3: 实现 EventTap 生命周期**

事件 mask 包含键盘 Down/Up、flagsChanged 和鼠标 Down/Up。回调只提取 Sendable 快照，然后在主线程/主 actor 内调用 matcher；必须在 CGEvent 回调返回前决定是否返回 `nil` 或原事件，不能异步后再消费。

Tap 禁用时执行：清空 active sessions、尝试重新启用一次、失败后发布 `.eventTapUnavailable`。

- [ ] **Step 4: 实现全局录制器**

录制器使用单独的 CGEventTap，监听键盘、flagsChanged 和鼠标按钮；ESC 取消录制；10 秒超时；录制成功只返回一个 `TriggerEvent`。录制器不把 CGEvent 跨并发传递，完成时只回传值类型快照。

- [ ] **Step 5: 运行 GREEN**

运行：`swift test --filter ShortcutEventMonitorTests`。  
运行：`swift test` 和 `swift build -c release`。

---

### Task 5: 重建设置 UI 和绑定生命周期

**Files:**
- Modify: `Sources/MenuTools/ShortcutSettingsView.swift`
- Modify: `Sources/MenuTools/SettingsView.swift`
- Modify: `Sources/MenuTools/MenuToolsApp.swift`
- Modify: `Resources/en.lproj/Localizable.strings`
- Modify: `Resources/ja.lproj/Localizable.strings`
- Modify: `Resources/ko.lproj/Localizable.strings`
- Modify: `Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Resources/zh-Hant.lproj/Localizable.strings`
- Create: `Tests/MenuToolsTests/ShortcutSettingsStateTests.swift`

**Interfaces:**
- View 持有 `ShortcutBindingStore` 和 `ShortcutEventMonitor` 的观察状态，不直接操作 CGEventTap。
- `MenuToolsApp.init()` 创建并启动 monitor；设置页关闭不停止全局 monitor，只停止 trigger recorder。

- [ ] **Step 1: 写失败测试，覆盖添加、编辑、删除和停用状态**

```swift
@Test("停用绑定不会从持久化列表删除")
func disablingBindingKeepsBinding() {
    let testTrigger = TriggerEvent(type: .keyboard, code: 40, modifiers: 256, deviceFilter: nil)
    let binding = ShortcutBinding(trigger: testTrigger, action: .system("showDesktop"))
    var store = ShortcutBindingStore(bindings: [binding])

    #expect(store.setEnabled(id: binding.id, enabled: false))
    #expect(store.bindings.first?.isEnabled == false)
}
```

- [ ] **Step 2: 运行 RED**

运行：`swift test --filter ShortcutSettingsStateTests`。  
预期：FAIL，原因是新 UI 状态/Store 接口尚未接入。

- [ ] **Step 3: 重建绑定列表 UI**

列表行展示 trigger、action、enabled 状态和错误状态；添加流程先选动作再启动全局 recorder。绑定保存使用 store 的冲突结果，失败时不退出编辑状态并显示本地化错误。

- [ ] **Step 4: 接入权限提示和系统设置跳转**

显示 Accessibility/Automation 两个独立状态卡；监听权限恢复后重启 monitor。录制期间关闭设置窗口必须通过 recorder 的 teardown 移除 tap。

- [ ] **Step 5: 更新五份本地化文案并运行 GREEN**

新增绑定、录制、删除、停用、冲突、监听器不可用、Accessibility、Automation、App/脚本/文件错误文案。运行：`swift test`、`swift build -c release`。

---

### Task 6: 删除旧 Carbon 管理器并完成应用接线

**Files:**
- Delete or replace: `Sources/MenuTools/ShortcutManager.swift`
- Delete or replace: `Tests/MenuToolsTests/ShortcutManagerTests.swift`
- Modify or replace: `Tests/MenuToolsTests/ShortcutActionTests.swift`
- Modify or replace: `Tests/MenuToolsTests/ShortcutBindingStateTests.swift`
- Modify: `Sources/MenuTools/MenuToolsApp.swift`
- Modify: `Package.swift`
- Modify: `Resources/Info.plist`
- Modify: `docs/superpowers/specs/2026-08-06-mos-style-shortcut-system-design.md`

**Interfaces:**
- 应用只保留 `ShortcutEventMonitor`、`ShortcutBindingStore` 和 `ShortcutActionExecutor` 三个生产入口。
- `MenuToolsApp` 启动顺序：权限服务初始化 -> store 加载 -> executor 创建 -> event monitor 启动。

- [ ] **Step 1: 写失败集成检查**

执行静态检查命令确认旧 API 尚未删除：

```bash
rg "RegisterEventHotKey|UnregisterEventHotKey|EventHotKeyRef" Sources/MenuTools
```

预期：当前旧管理器仍有匹配结果，作为 RED 基线。

- [ ] **Step 2: 删除旧 Carbon 路径**

移除 `ShortcutManager` 的 Carbon 注册和旧 `[String: KeyCombo]` 存储；删除旧 `shortcutBindings` 写入逻辑；保持 `ShortcutActionCatalog` 作为动作目录而不是热键注册入口。

- [ ] **Step 3: 清理旧配置 key 并验证新启动流程**

首次启动新系统时删除旧 `shortcutBindings`；启动过程中若权限不足，UI 显示监听器不可用但不丢新 JSON 配置。

- [ ] **Step 4: 运行静态检查、测试和构建**

运行：`rg "RegisterEventHotKey|UnregisterEventHotKey|EventHotKeyRef" Sources/MenuTools`，预期无输出。  
运行：`swift test`。  
运行：`swift build -c release`。

---

### Task 7: 打包、实机验证和最终审查

**Files:**
- Modify only when verification reveals a defect: affected source/test/localization files
- Verification: `dist/MenuTools.app`

- [ ] **Step 1: 运行完整构建和打包**

运行：`./build.sh`。  
预期：Swift release build、Finder 扩展构建、签名和 `.app` 组装全部成功。

- [ ] **Step 2: 运行纯逻辑和配置验证**

运行：`swift test`。  
运行：`plutil -lint Resources/Info.plist Resources/MenuTools.entitlements Extension/Info.plist Extension/RightClickTools.entitlements`。  
运行：`git diff --check`。

- [ ] **Step 3: 执行 macOS 26 实机清单**

- 普通键盘组合键录制、保存、触发、删除
- 单独 Command/Option/Control/Shift/Fn
- 鼠标左键、右键、中键和其他鼠标按钮
- 同一触发器冲突提示
- 绑定停用后原事件放行
- 空间切换动画和菜单栏状态
- Command-Tab 修饰键保留
- App、脚本、文件动作
- Accessibility/Automation 撤销与恢复
- 设置窗口关闭时 recorder tap 清理
- VoiceOver 读取绑定列表和错误卡

- [ ] **Step 4: 最终静态审查**

确认以下条件：

- `RegisterEventHotKey` 不再出现
- SkyLight 空间切换 API 不再出现
- UserDefaults 使用 `shortcutBindingsV2`
- 脚本动作不经过 shell
- 事件 tap 失败不会吞掉原事件
- `activeBindings` 在所有 tap 停止路径清空
