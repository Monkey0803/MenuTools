import AppKit
import Foundation
import Testing
@testable import MenuTools

@Test("窗口管理面板快捷键可持久化且与布局快捷键互斥")
@MainActor
func windowManagementQuickAccessShortcutPersistsAndRejectsLayoutConflict() throws {
    let suiteName = "MenuTools-WindowQuickAccessShortcutTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let shortcut = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let service = WindowShortcutService(
        defaults: defaults,
        conflictChecker: NoShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        clipboardBindingProvider: { nil },
        appVolumeBindingProvider: { nil },
        onQuickAccessTrigger: {}
    )

    try service.setQuickAccessBinding(shortcut)
    #expect(service.quickAccessBinding == shortcut)
    #expect(throws: WindowShortcutError.conflict(.leftHalf)) {
        try service.setBinding(shortcut, for: .leftHalf)
    }

    let restored = WindowShortcutService(
        defaults: defaults,
        conflictChecker: NoShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        clipboardBindingProvider: { nil },
        appVolumeBindingProvider: { nil },
        onQuickAccessTrigger: {}
    )
    #expect(restored.quickAccessBinding == shortcut)

    restored.clearQuickAccessBinding()
    #expect(restored.quickAccessBinding == nil)
}

@Test("统一冲突检测会识别窗口管理面板快捷键")
@MainActor
func shortcutConflictCheckerDetectsWindowManagementQuickAccessBinding() {
    let shortcut = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let checker = DefaultShortcutConflictChecker(
        systemProvider: NoSystemShortcutProvider(),
        externalProbe: NoExternalShortcutProbe()
    )
    let context = ShortcutConflictContext(
        sceneBindings: [:],
        windowBindings: [:],
        appBindings: [:],
        screenshotBindings: [:],
        clipboardBinding: nil,
        appVolumeBinding: nil,
        excludingScene: nil,
        excludingWindow: nil,
        excludingAppPath: nil,
        excludingScreenshotMode: nil,
        excludingClipboard: false,
        excludingAppVolume: false,
        windowQuickAccessBinding: shortcut
    )

    #expect(checker.conflict(for: shortcut, context: context) == .windowManagement)
}

@Test("窗口管理面板快捷键触发一次展示且忽略双监听重复事件")
@MainActor
func windowManagementQuickAccessShortcutTriggersPanelOnce() async throws {
    let suiteName = "WindowShortcutServiceTests.trigger.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    let monitor = WindowShortcutEventMonitorSpy()
    let shortcut = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    var triggerCount = 0
    let service = WindowShortcutService(
        defaults: defaults,
        conflictChecker: NoShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        clipboardBindingProvider: { nil },
        appVolumeBindingProvider: { nil },
        eventMonitor: monitor,
        onQuickAccessTrigger: { triggerCount += 1 }
    )
    try service.setQuickAccessBinding(shortcut)
    service.start()

    let globalEvent = try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.control, .option],
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        characters: "1",
        charactersIgnoringModifiers: "1",
        isARepeat: false,
        keyCode: shortcut.keyCode
    ))
    let localEvent = try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.control, .option],
        timestamp: 1.1,
        windowNumber: 0,
        context: nil,
        characters: "1",
        charactersIgnoringModifiers: "1",
        isARepeat: false,
        keyCode: shortcut.keyCode
    ))
    monitor.sendGlobal(globalEvent)
    monitor.sendLocal(localEvent)
    await Task.yield()

    #expect(triggerCount == 1)
    service.stop()
    #expect(monitor.removedMonitorCount == 2)
}

@Test("窗口管理面板展示前先锁定外部前台应用")
@MainActor
func windowManagementQuickAccessCapturesTargetBeforePresentation() async throws {
    let suiteName = "WindowShortcutServiceTests.target.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    let monitor = WindowShortcutEventMonitorSpy()
    let shortcut = GlobalShortcut(keyCode: 19, modifiers: GlobalShortcutModifier.controlOption)
    var events: [String] = []
    let service = WindowShortcutService(
        defaults: defaults,
        conflictChecker: NoShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        clipboardBindingProvider: { nil },
        appVolumeBindingProvider: { nil },
        eventMonitor: monitor,
        prepareQuickAccessTarget: { events.append("target") },
        onQuickAccessTrigger: { events.append("present") }
    )
    try service.setQuickAccessBinding(shortcut)
    service.start()

    let event = try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.control, .option],
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        characters: "2",
        charactersIgnoringModifiers: "2",
        isARepeat: false,
        keyCode: shortcut.keyCode
    ))
    monitor.sendGlobal(event)
    await Task.yield()

    #expect(events == ["target", "present"])
    service.stop()
}

@MainActor
private struct NoSystemShortcutProvider: SystemShortcutProviding {
    func contains(_ shortcut: GlobalShortcut) -> Bool { false }
}

@MainActor
private struct NoExternalShortcutProbe: ExternalShortcutProbing {
    func contains(_ shortcut: GlobalShortcut) -> Bool { false }
}

@MainActor
private final class WindowShortcutEventMonitorSpy: WindowShortcutEventMonitoring {
    private var globalHandler: ((NSEvent) -> Void)?
    private var localHandler: ((NSEvent) -> NSEvent?)?
    private var monitors: [NSObject] = []
    private(set) var removedMonitorCount = 0

    func addGlobalKeyDownMonitor(_ handler: @escaping (NSEvent) -> Void) -> Any? {
        globalHandler = handler
        let monitor = NSObject()
        monitors.append(monitor)
        return monitor
    }

    func addLocalKeyDownMonitor(_ handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        localHandler = handler
        let monitor = NSObject()
        monitors.append(monitor)
        return monitor
    }

    func removeMonitor(_ monitor: Any) {
        guard let monitor = monitor as? NSObject,
              monitors.contains(where: { $0 === monitor }) else { return }
        removedMonitorCount += 1
    }

    func sendGlobal(_ event: NSEvent) { globalHandler?(event) }
    func sendLocal(_ event: NSEvent) { _ = localHandler?(event) }
}

private struct NoShortcutConflictChecker: ShortcutConflictChecking {
    func conflict(for shortcut: GlobalShortcut, context: ShortcutConflictContext) -> ShortcutConflictSource? {
        nil
    }
}

@Test("窗口快捷键能匹配布局")
func windowShortcutMatchesLayout() {
    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let bindings = [WindowLayout.maxWidth: binding]

    #expect(WindowShortcutCatalog.match(
        keyCode: 18,
        modifiers: GlobalShortcutModifier.controlOption,
        bindings: bindings
    ) == .maxWidth)
    #expect(WindowShortcutCatalog.match(keyCode: 19, modifiers: 0, bindings: bindings) == nil)
}

@Test("窗口快捷键能发现重复绑定")
func windowShortcutDetectsConflict() {
    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let bindings = [WindowLayout.maxWidth: binding, WindowLayout.centered: binding]

    #expect(WindowShortcutCatalog.conflict(for: binding, excluding: .maxWidth, in: bindings) == .centered)
}

@Test("窗口快捷键服务可以持久化绑定")
@MainActor
func windowShortcutServicePersistsBinding() throws {
    let suiteName = "MenuToolsTests.WindowShortcutService.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let service = WindowShortcutService(
        defaults: defaults,
        conflictChecker: NoShortcutConflictChecker(),
        sceneBindingsProvider: { [:] }
    )
    try service.setBinding(binding, for: .maxWidth)

    let restored = WindowShortcutService(
        defaults: defaults,
        conflictChecker: NoShortcutConflictChecker(),
        sceneBindingsProvider: { [:] }
    )
    #expect(restored.binding(for: .maxWidth) == binding)
}

@Test("窗口快捷键可以发现场景快捷键交叉冲突")
func windowShortcutDetectsSceneConflict() {
    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let bindings = [ScenePreset.work: binding]

    #expect(ShortcutBindingConflictCatalog.sceneConflict(for: binding, in: bindings) == .work)
}

@Test("窗口预设快捷键可持久化，并与布局、预设、快速面板快捷键互斥")
@MainActor
func windowPresetShortcutPersistsAndRejectsConflicts() throws {
    let suiteName = "MenuTools-WindowPresetShortcutTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let presetA = WindowLayoutPreset(
        name: "开发",
        layout: .centered,
        frame: CGRect(x: 0, y: 0, width: 800, height: 600)
    )
    let presetB = WindowLayoutPreset(name: "阅读", layout: .centered, frame: CGRect(x: 10, y: 10, width: 900, height: 700))
    let shortcutA = GlobalShortcut(keyCode: 19, modifiers: GlobalShortcutModifier.controlOption)
    let layoutShortcut = GlobalShortcut(keyCode: 20, modifiers: GlobalShortcutModifier.controlOption)

    let service = WindowShortcutService(
        defaults: defaults,
        conflictChecker: NoShortcutConflictChecker(),
        sceneBindingsProvider: { [:] }
    )
    #expect(service.presetBinding(for: presetA.id) == nil)

    try service.setPresetBinding(shortcutA, for: presetA)
    #expect(service.presetBinding(for: presetA.id) == shortcutA)

    // 与布局绑定互斥（双向）
    try service.setBinding(layoutShortcut, for: .leftHalf)
    #expect(throws: WindowShortcutError.conflict(.leftHalf)) {
        try service.setPresetBinding(layoutShortcut, for: presetB)
    }
    // 布局反向撞预设时，报出的是预设（已有绑定的那一侧），比报“与左半屏冲突”更准确。
    #expect(throws: WindowShortcutError.presetConflict("开发")) {
        try service.setBinding(shortcutA, for: .leftHalf)
    }

    // 预设之间互斥
    #expect(throws: WindowShortcutError.presetConflict("开发")) {
        try service.setPresetBinding(shortcutA, for: presetB)
    }

    // 与快速面板快捷键互斥（同样报出已占用该快捷键的预设）
    #expect(throws: WindowShortcutError.presetConflict("开发")) {
        try service.setQuickAccessBinding(shortcutA)
    }

    // 重新创建服务后绑定仍然有效
    let restored = WindowShortcutService(
        defaults: defaults,
        conflictChecker: NoShortcutConflictChecker(),
        sceneBindingsProvider: { [:] }
    )
    #expect(restored.presetBinding(for: presetA.id) == shortcutA)

    restored.clearPresetBinding(for: presetA.id)
    #expect(restored.presetBinding(for: presetA.id) == nil)
}

@Test("同一预设改绑快捷键会覆盖旧绑定且不留下重复项")
@MainActor
func windowPresetShortcutRebindingReplacesOldValue() throws {
    let suiteName = "MenuTools-WindowPresetShortcutTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let preset = WindowLayoutPreset(name: "开发", layout: .leftHalf)
    let first = GlobalShortcut(keyCode: 19, modifiers: GlobalShortcutModifier.controlOption)
    let second = GlobalShortcut(keyCode: 20, modifiers: GlobalShortcutModifier.controlOption)

    let service = WindowShortcutService(
        defaults: defaults,
        conflictChecker: NoShortcutConflictChecker(),
        sceneBindingsProvider: { [:] }
    )
    try service.setPresetBinding(first, for: preset)
    try service.setPresetBinding(second, for: preset)

    #expect(service.presetBinding(for: preset.id) == second)
    #expect(service.presetShortcuts.count == 1)
}

@Test("统一冲突检测会识别窗口预设快捷键")
@MainActor
func shortcutConflictCheckerDetectsWindowPresetBinding() {
    let preset = WindowPresetShortcut(
        id: UUID(),
        name: "开发",
        shortcut: GlobalShortcut(keyCode: 21, modifiers: GlobalShortcutModifier.controlOption)
    )
    let checker = DefaultShortcutConflictChecker(
        systemProvider: NoSystemShortcutProvider(),
        externalProbe: NoExternalShortcutProbe()
    )
    let context = ShortcutConflictContext(
        sceneBindings: [:],
        windowBindings: [:],
        appBindings: [:],
        screenshotBindings: [:],
        clipboardBinding: nil,
        appVolumeBinding: nil,
        excludingScene: nil,
        excludingWindow: nil,
        excludingAppPath: nil,
        excludingScreenshotMode: nil,
        excludingClipboard: false,
        excludingAppVolume: false,
        windowPresetBindings: [preset]
    )

    #expect(checker.conflict(for: preset.shortcut, context: context) == .windowPreset("开发"))
    #expect(checker.conflict(
        for: GlobalShortcut(keyCode: 22, modifiers: GlobalShortcutModifier.controlOption),
        context: context
    ) == nil)
}

@Test("窗口快捷键能匹配到预设绑定")
func windowShortcutMatchesPresetBinding() {
    let presetID = UUID()
    let shortcut = GlobalShortcut(keyCode: 23, modifiers: GlobalShortcutModifier.controlOption)
    let bindings = [WindowPresetShortcut(id: presetID, name: "开发", shortcut: shortcut)]

    #expect(WindowShortcutCatalog.matchPreset(
        keyCode: shortcut.keyCode,
        modifiers: shortcut.modifiers,
        bindings: bindings
    ) == presetID)
    #expect(WindowShortcutCatalog.matchPreset(
        keyCode: 24,
        modifiers: shortcut.modifiers,
        bindings: bindings
    ) == nil)
    #expect(WindowShortcutCatalog.matchPreset(
        keyCode: shortcut.keyCode,
        modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue,
        bindings: bindings
    ) == nil)
}
