import AppKit
import Foundation
import Testing
@testable import MenuTools

@MainActor
private struct AppVolumeShortcutConflictChecker: ShortcutConflictChecking {
    func conflict(
        for shortcut: GlobalShortcut,
        context: ShortcutConflictContext
    ) -> ShortcutConflictSource? {
        nil
    }
}

@Test("音量快捷键可精确匹配")
func appVolumeShortcutMatchesBinding() {
    let shortcut = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)

    #expect(AppVolumeShortcutCatalog.matches(
        keyCode: shortcut.keyCode,
        modifiers: shortcut.modifiers,
        binding: shortcut
    ))
    #expect(!AppVolumeShortcutCatalog.matches(
        keyCode: 19,
        modifiers: shortcut.modifiers,
        binding: shortcut
    ))
}

@Test("音量快捷面板展示全部 App，不截断为前三项")
func appVolumeQuickAccessDisplaysAllSessions() {
    let sessions = (1...4).map { index in
        AppAudioSession(
            rootBundleID: "com.example.app\(index)",
            displayName: "App \(index)",
            bundleURL: nil,
            processObjectIDs: [],
            audioBundleIDs: [],
            isRunningOutput: true,
            volume: 1,
            lastAdjustedAt: .distantPast,
            errorMessage: nil
        )
    }

    #expect(AppVolumeQuickAccessLayout.displayedSessions(from: sessions) == sessions)
}

@Test("已记忆的 App 也可预设下次启动的音量")
func rememberedAppVolumeRowRemainsAdjustable() {
    #expect(AppVolumeRowInteractionPolicy.canAdjust(isEnabled: true))
    #expect(!AppVolumeRowInteractionPolicy.canAdjust(isEnabled: false))
}

@Test("系统输入输出行使用统一高度确保控件垂直居中")
func systemVolumeRowsUseSharedControlHeight() {
    #expect(AppVolumeSystemRowLayout.expandedControlHeight == 32)
}

@Test("音量图标会随静音和音量档位变化")
func appVolumeIconReflectsCurrentLevel() {
    #expect(AppVolumeIconPolicy.symbolName(volume: 0.8, isMuted: true) == "speaker.slash.fill")
    #expect(AppVolumeIconPolicy.symbolName(volume: 0, isMuted: false) == "speaker.slash.fill")
    #expect(AppVolumeIconPolicy.symbolName(volume: 0.2, isMuted: false) == "speaker.wave.1.fill")
    #expect(AppVolumeIconPolicy.symbolName(volume: 1.0 / 3.0, isMuted: false) == "speaker.wave.2.fill")
    #expect(AppVolumeIconPolicy.symbolName(volume: 0.5, isMuted: false) == "speaker.wave.2.fill")
    #expect(AppVolumeIconPolicy.symbolName(volume: 2.0 / 3.0, isMuted: false) == "speaker.wave.3.fill")
    #expect(AppVolumeIconPolicy.symbolName(volume: 0.8, isMuted: false) == "speaker.wave.3.fill")
}

@Test("音量快捷键会持久化且可清除")
@MainActor
func appVolumeShortcutPersistsAndClearsBinding() throws {
    let suiteName = "MenuTools-AppVolumeShortcutTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let shortcut = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let service = AppVolumeShortcutService(
        defaults: defaults,
        conflictChecker: AppVolumeShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        clipboardBindingProvider: { nil },
        onTrigger: {}
    )

    try service.setBinding(shortcut)
    #expect(service.binding == shortcut)

    let restored = AppVolumeShortcutService(
        defaults: defaults,
        conflictChecker: AppVolumeShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        clipboardBindingProvider: { nil },
        onTrigger: {}
    )
    #expect(restored.binding == shortcut)

    restored.clearBinding()
    #expect(restored.binding == nil)
}

@Test("音量快捷键拒绝与剪贴板快捷键冲突")
@MainActor
func appVolumeShortcutRejectsClipboardBinding() {
    let shortcut = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let service = AppVolumeShortcutService(
        conflictChecker: DefaultShortcutConflictChecker(
            systemProvider: AppVolumeShortcutSystemProvider(),
            externalProbe: AppVolumeShortcutExternalProbe()
        ),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        clipboardBindingProvider: { shortcut },
        onTrigger: {}
    )

    #expect(throws: AppVolumeShortcutError.clipboardConflict) {
        try service.setBinding(shortcut)
    }
}

@Test("音量快捷键忽略自动重复和双监听重复事件")
func appVolumeShortcutEventGatePreventsRepeatedPresentation() {
    var gate = AppVolumeShortcutEventGate()

    let firstAccepted = gate.accept(
        keyCode: 18,
        modifiers: GlobalShortcutModifier.controlOption,
        timestamp: 1,
        isARepeat: false
    )
    let duplicateAccepted = gate.accept(
        keyCode: 18,
        modifiers: GlobalShortcutModifier.controlOption,
        timestamp: 1.1,
        isARepeat: false
    )
    let repeatAccepted = gate.accept(
        keyCode: 18,
        modifiers: GlobalShortcutModifier.controlOption,
        timestamp: 1.5,
        isARepeat: true
    )

    #expect(firstAccepted)
    #expect(!duplicateAccepted)
    #expect(!repeatAccepted)
}

@Test("音量增减快捷键允许节流后的按住连续调节")
func appVolumeShortcutEventGateAllowsThrottledRepeats() {
    var gate = AppVolumeShortcutEventGate()

    let firstAccepted = gate.accept(
        keyCode: 18, modifiers: GlobalShortcutModifier.controlOption,
        timestamp: 1, isARepeat: false, allowsRepeat: true
    )
    let earlyRepeatAccepted = gate.accept(
        keyCode: 18, modifiers: GlobalShortcutModifier.controlOption,
        timestamp: 1.02, isARepeat: true, allowsRepeat: true
    )
    let throttledRepeatAccepted = gate.accept(
        keyCode: 18, modifiers: GlobalShortcutModifier.controlOption,
        timestamp: 1.06, isARepeat: true, allowsRepeat: true
    )

    #expect(firstAccepted)
    #expect(!earlyRepeatAccepted)
    #expect(throttledRepeatAccepted)
}

@Test("音量快捷键启动后触发一次并在停止时移除监听")
@MainActor
func appVolumeShortcutServiceManagesMonitorLifecycle() async throws {
    let suiteName = "AppVolumeShortcutServiceTests.lifecycle.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    let monitor = AppVolumeShortcutEventMonitorSpy()
    let shortcut = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    var triggerCount = 0
    let service = AppVolumeShortcutService(
        defaults: defaults,
        conflictChecker: AppVolumeShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        clipboardBindingProvider: { nil },
        eventMonitor: monitor,
        onTrigger: { triggerCount += 1 }
    )
    try service.setBinding(shortcut)

    service.start()
    #expect(service.isRunning)

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

    #expect(!service.isRunning)
    #expect(monitor.removedMonitorCount == 2)
}

@Test("音量增减与静音快捷键会分派对应动作且单独持久化")
@MainActor
func appVolumeShortcutActionsDispatchIndependently() throws {
    let suiteName = "AppVolumeShortcutServiceTests.actions.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let increase = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let mute = GlobalShortcut(keyCode: 19, modifiers: GlobalShortcutModifier.controlOption)
    var actions: [AppVolumeShortcutAction] = []
    let service = AppVolumeShortcutService(
        defaults: defaults,
        conflictChecker: AppVolumeShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        clipboardBindingProvider: { nil },
        eventMonitor: AppVolumeShortcutEventMonitorSpy(),
        onAction: { actions.append($0) }
    )

    try service.setBinding(increase, for: .increase)
    try service.setBinding(mute, for: .toggleMute)

    #expect(service.bindings[.increase] == increase)
    #expect(service.bindings[.toggleMute] == mute)
    #expect(AppVolumeShortcutCatalog.matches(keyCode: increase.keyCode, modifiers: increase.modifiers, binding: service.bindings[.increase]))
}

@Test("App 音量快捷键冲突会被统一冲突检测识别")
@MainActor
func shortcutConflictCheckerDetectsAppVolumeBinding() {
    let shortcut = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let checker = DefaultShortcutConflictChecker(
        systemProvider: AppVolumeShortcutSystemProvider(),
        externalProbe: AppVolumeShortcutExternalProbe()
    )
    let context = ShortcutConflictContext(
        sceneBindings: [:],
        windowBindings: [:],
        appBindings: [:],
        screenshotBindings: [:],
        clipboardBinding: nil,
        appVolumeBinding: shortcut,
        excludingScene: nil,
        excludingWindow: nil,
        excludingAppPath: nil,
        excludingScreenshotMode: nil,
        excludingClipboard: false,
        excludingAppVolume: false
    )

    #expect(checker.conflict(for: shortcut, context: context) == .appVolume)
}

@MainActor
private struct AppVolumeShortcutSystemProvider: SystemShortcutProviding {
    func contains(_ shortcut: GlobalShortcut) -> Bool { false }
}

@MainActor
private struct AppVolumeShortcutExternalProbe: ExternalShortcutProbing {
    func contains(_ shortcut: GlobalShortcut) -> Bool { false }
}

@MainActor
private final class AppVolumeShortcutEventMonitorSpy: AppVolumeShortcutEventMonitoring {
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
              monitors.contains(where: { $0 === monitor }) else {
            return
        }
        removedMonitorCount += 1
    }

    func sendGlobal(_ event: NSEvent) {
        globalHandler?(event)
    }

    func sendLocal(_ event: NSEvent) {
        _ = localHandler?(event)
    }
}
