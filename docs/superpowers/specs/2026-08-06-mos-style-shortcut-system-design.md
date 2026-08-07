# Mos 风格通用快捷键系统设计

## 目标

将 MenuTools 当前“每个系统动作独立注册一个 Carbon 全局快捷键”的模型，重构为 Mos 风格的统一输入绑定系统：

```text
TriggerEvent -> ShortcutAction
```

首版支持键盘、单独修饰键和鼠标按钮作为触发器，并支持现有系统动作、打开 App、运行脚本和打开文件。

## 已确认决策

- 采用完整替换，不保留旧 Carbon `RegisterEventHotKey` 运行时系统。
- 允许破坏性重置，不迁移旧 `shortcutBindings` 数据。
- 现有九个系统动作保留为 Action Catalog，但不保留旧的“一动作一快捷键”界面。
- 首版支持普通键、组合键、单独修饰键和鼠标按钮。
- 首版包含结构化的 App、脚本和文件动作。
- 空间切换使用 macOS 标准 `System Events` 的 `Control+方向键`，不调用 SkyLight 私有 API。

## 非目标

- 不兼容旧 `shortcutBindings` JSON 格式。
- 不支持 Logitech HID++ 专用按钮协议；鼠标按钮先覆盖 CGEvent 可见的鼠标按钮。
- 不实现跨设备同步或云端配置。
- 不在首版实现复杂的多步组合键序列、双击触发或手势识别。

## 核心模型

### TriggerEvent

触发器必须同时保存事件类别、键码/按钮码和修饰键。显示字符串不是身份字段。

```swift
enum TriggerEventType: String, Codable {
    case keyboard
    case modifier
    case mouse
}

struct TriggerEvent: Codable, Equatable, Hashable {
    let type: TriggerEventType
    let code: UInt16
    let modifiers: UInt64
    let deviceFilter: DeviceFilter?
}

struct DeviceFilter: Codable, Equatable, Hashable {
    let vendorID: UInt16?
    let productID: UInt16?
}

enum EventPhase: String, Codable, Equatable, Sendable {
    case down
    case up
}
```

冲突身份只比较：

- `type`
- `code`
- `modifiers` 中定义的修饰键位
- `deviceFilter`

不比较本地化文案或格式化后的显示字符串。

### ShortcutAction

绑定动作采用带 payload 的结构，而不是把参数编码进字符串：

```swift
enum ShortcutActionKind: String, Codable {
    case system
    case openTarget
}

struct ShortcutActionPayload: Codable, Equatable {
    let kind: ShortcutActionKind
    let systemAction: String?
    let target: OpenTargetPayload?
}
```

`systemAction` 使用现有九个系统动作的 raw value；`target` 支持：

- `.application`：App 路径、bundle identifier、启动参数
- `.script`：可执行脚本路径和参数数组
- `.file`：普通文件路径，由 `NSWorkspace` 打开

### ShortcutBinding

```swift
struct ShortcutBinding: Codable, Equatable, Identifiable {
    let id: UUID
    var trigger: TriggerEvent
    var action: ShortcutActionPayload
    var isEnabled: Bool
    var executionMode: ShortcutExecutionMode
    let createdAt: Date
}

enum ShortcutExecutionMode: String, Codable {
    case trigger
    case stateful
}
```

首版系统动作默认使用 `trigger`。未来需要按住执行的动作使用 `stateful`，由 `activeBindings` 配对 Down/Up。

## 运行时架构

### ShortcutEventMonitor

应用启动后只建立一个全局 `CGEventTap`，监听：

- `keyDown`
- `keyUp`
- `flagsChanged`
- `leftMouseDown/rightMouseDown/otherMouseDown`
- 对应的 mouse up 事件

事件回调提取成 Sendable 的 `EventSnapshot`，避免把非 Sendable 的 `CGEvent` 跨并发边界传递。事件 tap 被系统禁用时：

1. 清空 `activeBindings`
2. 尝试重新启用一次
3. 失败后将监听器状态置为不可用并向 UI 报告

MenuTools 注入的合成事件使用固定 `eventSourceUserData` 标记，监视器直接放行，防止递归触发。

### ShortcutBindingMatcher

匹配规则：

- Down 事件按 type、code、modifiers、deviceFilter 精确匹配
- Up 事件优先从 `activeBindings` 查找，不重新依赖当前 modifiers
- 状态型动作的 Down 创建会话，Up 释放会话
- 触发型动作只处理 Down
- 绑定禁用或未匹配时放行原事件

匹配成功且动作可以执行时消费原事件；权限不足或动作不可用时放行原事件并显示错误。

### ShortcutActionExecutor

执行器分为两类：

- 系统动作：复用现有 `ShortcutAction` 的动作定义和执行结果
- 结构化目标：
  - App 使用 `NSWorkspace.openApplication`
  - 脚本使用 `Process`，参数按结构化参数数组传递，禁止拼接 shell 命令
  - 文件使用 `NSWorkspace.open`

空间切换只使用标准 System Events：

```applescript
tell application "System Events"
    key code 123 using control down
end tell
```

左右方向键码根据动作决定。系统动作不再调用 SkyLight 私有 API。

## 持久化

新 key：`shortcutBindingsV2`。

存储为 JSON 数组。首次启用新系统时：

- 读取新 key
- 清理旧 `shortcutBindings`
- 不迁移旧绑定
- 单条 JSON 解码失败只隔离该条，不影响其他绑定
- 绑定保存成功后才更新内存和运行时状态

## 权限和错误处理

需要区分：

- Accessibility：创建 CGEventTap、注入合成键鼠事件
- Automation：通过 System Events 执行空间切换

UI 显示：

- 事件监听状态
- Accessibility 状态和跳转按钮
- Automation 状态和跳转按钮
- 单条绑定的启用、不可用、权限不足、动作失败状态

错误结果包括：

- `.eventTapUnavailable`
- `.accessibilityRequired`
- `.automationRequired`
- `.actionUnavailable`
- `.executionFailed`
- `.duplicateTrigger`

权限不足不能静默消费用户原事件，也不能自动删除绑定。

## 设置 UI

设置页改为绑定列表：

```text
快捷键绑定
监听状态：已启用

⌥⌘←      向左移动空间       已启用
鼠标侧键   打开 Safari         已启用
⌃⌥K      显示桌面             已启用

                    添加绑定
```

添加流程：

1. 点击添加绑定
2. 选择系统动作或结构化目标动作
3. 录制键盘、修饰键或鼠标按钮
4. 检查并显示冲突
5. 保存绑定

每条绑定支持启用/停用、重新录制、修改动作和删除。

录制器使用全局 `CGEventTap`，支持 combination、singleKey、adaptive 三种模式；不再使用 `NSEvent.addLocalMonitorForEvents` 作为唯一录制通道。

## 文件边界

新增：

- `ShortcutTrigger.swift`
- `ShortcutBinding.swift`
- `ShortcutBindingStore.swift`
- `ShortcutEventMonitor.swift`
- `ShortcutBindingMatcher.swift`
- `ShortcutActionCatalog.swift`
- `ShortcutActionExecutor.swift`
- `ShortcutPermissionService.swift`
- `ShortcutTriggerRecorder.swift`
- `OpenTargetPayload.swift`

修改：

- `MenuToolsApp.swift`
- `ShortcutSettingsView.swift`
- `ShortcutAction.swift`
- `SpaceService.swift`
- `Package.swift`

删除或停止使用：

- `RegisterEventHotKey`
- 旧 `ShortcutManager` Carbon 注册实现
- 旧一动作一绑定设置 UI
- 旧本地 `NSEvent` 录制监听器

## 测试策略

纯逻辑测试：

- TriggerEvent 身份和冲突比较
- 键盘、修饰键、鼠标事件匹配
- Down/Up active session 配对
- JSON 编解码和单条损坏隔离
- OpenTargetPayload 不变量
- 动作结果到 UI 错误的映射
- 合成事件标记过滤

注入测试：

- Fake EventTap 的启动、停止和重启
- Fake ActionExecutor 的成功、权限失败、执行失败
- Fake PermissionProvider 的权限恢复
- Fake ProcessLauncher 的 App、脚本和文件动作
- 绑定保存失败时内存状态不提交

实机验证：

- 普通键盘组合键
- 单独 Command/Option/Control/Shift/Fn
- 鼠标按钮
- 空间切换动画和菜单栏状态
- Command-Tab 等保留修饰键动作
- 录制窗口关闭和重新打开
- Accessibility/Automation 权限撤销与恢复
- VoiceOver 读取绑定和错误状态

## 验收标准

- 不再调用 `RegisterEventHotKey` 或 SkyLight 空间切换 API。
- 一个全局 CGEventTap 能处理键盘、修饰键和鼠标触发器。
- 绑定可持久化、可启用/停用、可删除、可重新录制。
- 相同 TriggerEvent 不能绑定多个动作。
- 事件未匹配或权限不足时原事件不会被误消费。
- 状态型动作 Down/Up 不会残留。
- 脚本动作不通过 shell 拼接执行。
- Swift Testing、release build、plist 检查全部通过。
- macOS 26 实机验证空间切换不会再产生用户截图中的菜单栏/窗口合成异常。
