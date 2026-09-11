import AppKit
import ApplicationServices
import Foundation
import Observation

@MainActor
protocol WindowShortcutEventMonitoring: AnyObject {
    func addGlobalKeyDownMonitor(_ handler: @escaping (NSEvent) -> Void) -> Any?
    func addLocalKeyDownMonitor(_ handler: @escaping (NSEvent) -> NSEvent?) -> Any?
    func removeMonitor(_ monitor: Any)
}

@MainActor
final class DefaultWindowShortcutEventMonitor: WindowShortcutEventMonitoring {
    func addGlobalKeyDownMonitor(_ handler: @escaping (NSEvent) -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    func addLocalKeyDownMonitor(_ handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    func removeMonitor(_ monitor: Any) {
        NSEvent.removeMonitor(monitor)
    }
}

struct WindowShortcutEventGate {
    private(set) var lastEvent: (keyCode: UInt16, modifiers: UInt, timestamp: TimeInterval)?

    mutating func accept(
        keyCode: UInt16,
        modifiers: UInt,
        timestamp: TimeInterval,
        isARepeat: Bool
    ) -> Bool {
        guard !isARepeat else { return false }
        defer { lastEvent = (keyCode, modifiers, timestamp) }
        guard let lastEvent else { return true }
        guard lastEvent.keyCode == keyCode,
              lastEvent.modifiers == modifiers else {
            return true
        }
        return timestamp - lastEvent.timestamp > 0.35
    }

    mutating func reset() {
        lastEvent = nil
    }
}

enum WindowShortcutError: LocalizedError, Equatable {
    case modifierRequired
    case conflict(WindowLayout)
    case systemConflict
    case otherApplicationConflict
    case sceneConflict(ScenePreset)
    case appConflict(String)
    case screenshotConflict
    case clipboardConflict
    case appVolumeConflict
    case translationConflict
    case quickAccessConflict
    case presetConflict(String)

    var errorDescription: String? {
        switch self {
        case .modifierRequired:
            return L("shortcut.error.modifierRequired")
        case let .conflict(layout):
            return L("shortcut.error.conflict", L(layout.titleKey))
        case .systemConflict:
            return L("shortcut.error.systemConflict")
        case .otherApplicationConflict:
            return L("shortcut.error.otherApplicationConflict")
        case let .sceneConflict(scene):
            return L("shortcut.error.conflict", L(scene.titleKey))
        case let .appConflict(path):
            return L(
                "shortcut.error.conflict",
                URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            )
        case .screenshotConflict:
            return L("shortcut.error.screenshotConflict")
        case .clipboardConflict:
            return L("shortcut.error.conflict", L("settings.tab.clipboard"))
        case .appVolumeConflict:
            return L("shortcut.error.conflict", L("settings.tab.volume"))
        case .translationConflict:
            return L("shortcut.error.conflict", L("settings.tab.translation"))
        case .quickAccessConflict:
            return L("shortcut.error.conflict", L("window.title"))
        case let .presetConflict(name):
            return L("shortcut.error.windowPresetConflict", name)
        }
    }
}

enum WindowShortcutCatalog {
    static func match(
        keyCode: UInt16,
        modifiers: UInt,
        bindings: [WindowLayout: GlobalShortcut]
    ) -> WindowLayout? {
        bindings.first {
            $0.value.keyCode == keyCode && $0.value.modifiers == modifiers
        }?.key
    }

    static func conflict(
        for binding: GlobalShortcut,
        excluding layout: WindowLayout,
        in bindings: [WindowLayout: GlobalShortcut]
    ) -> WindowLayout? {
        bindings.first { $0.key != layout && $0.value == binding }?.key
    }

    /// 匹配用户为「固定尺寸预设」绑定的全局快捷键。
    static func matchPreset(
        keyCode: UInt16,
        modifiers: UInt,
        bindings: [WindowPresetShortcut]
    ) -> UUID? {
        bindings.first {
            $0.shortcut.keyCode == keyCode && $0.shortcut.modifiers == modifiers
        }?.id
    }
}

/// 窗口布局快捷键的持久化与全局监听服务。
@MainActor
@Observable
final class WindowShortcutService {
    static let shared = WindowShortcutService()

    private(set) var bindings: [WindowLayout: GlobalShortcut]
    private(set) var quickAccessBinding: GlobalShortcut?
    private(set) var presetShortcuts: [WindowPresetShortcut]
    private(set) var lastError: String?
    private(set) var isRunning = false
    private(set) var isAccessibilityTrusted = AXIsProcessTrusted()

    private let defaults: UserDefaults
    private let conflictChecker: any ShortcutConflictChecking
    private let sceneBindingsProvider: @MainActor () -> [ScenePreset: GlobalShortcut]
    private let appBindingsProvider: @MainActor () -> [String: GlobalShortcut]
    private let screenshotBindingsProvider: @MainActor () -> [ScreenshotCaptureMode: GlobalShortcut]
    private let clipboardBindingProvider: @MainActor () -> GlobalShortcut?
    private let appVolumeBindingProvider: @MainActor () -> GlobalShortcut?
    private let eventMonitor: any WindowShortcutEventMonitoring
    private let prepareQuickAccessTarget: @MainActor () -> Void
    private let onQuickAccessTrigger: @MainActor () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventGate = WindowShortcutEventGate()

    init(
        defaults: UserDefaults = .standard,
        conflictChecker: any ShortcutConflictChecking = DefaultShortcutConflictChecker(),
        sceneBindingsProvider: @escaping @MainActor () -> [ScenePreset: GlobalShortcut] = { GlobalShortcutService.shared.bindings },
        appBindingsProvider: @escaping @MainActor () -> [String: GlobalShortcut] = { AppShortcutService.shared.bindings },
        screenshotBindingsProvider: @escaping @MainActor () -> [ScreenshotCaptureMode: GlobalShortcut] = { ScreenshotShortcutService.shared.bindings },
        clipboardBindingProvider: @escaping @MainActor () -> GlobalShortcut? = { ClipboardShortcutService.shared.binding },
        appVolumeBindingProvider: @escaping @MainActor () -> GlobalShortcut? = { AppVolumeShortcutService.shared.binding },
        eventMonitor: any WindowShortcutEventMonitoring = DefaultWindowShortcutEventMonitor(),
        prepareQuickAccessTarget: @escaping @MainActor () -> Void = { WindowManagementService.shared.rememberFrontmostExternalApplication() },
        onQuickAccessTrigger: @escaping @MainActor () -> Void = { MenuBarStatusItemController.shared.showWindowManagement() }
    ) {
        self.defaults = defaults
        self.bindings = Self.loadBindings(from: defaults)
        self.presetShortcuts = Self.loadPresetShortcuts(from: defaults)
        self.conflictChecker = conflictChecker
        self.sceneBindingsProvider = sceneBindingsProvider
        self.appBindingsProvider = appBindingsProvider
        self.screenshotBindingsProvider = screenshotBindingsProvider
        self.clipboardBindingProvider = clipboardBindingProvider
        self.appVolumeBindingProvider = appVolumeBindingProvider
        self.eventMonitor = eventMonitor
        self.prepareQuickAccessTarget = prepareQuickAccessTarget
        self.onQuickAccessTrigger = onQuickAccessTrigger
        self.quickAccessBinding = Self.loadQuickAccessBinding(from: defaults)
    }

    func start() {
        guard globalMonitor == nil && localMonitor == nil else { return }
        isAccessibilityTrusted = AXIsProcessTrusted()
        globalMonitor = eventMonitor.addGlobalKeyDownMonitor { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = GlobalShortcutCatalog.normalizedModifiers(event.modifierFlags)
            let timestamp = event.timestamp
            let isARepeat = event.isARepeat
            Task { @MainActor [weak self] in
                self?.handle(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    timestamp: timestamp,
                    isARepeat: isARepeat
                )
            }
        }
        localMonitor = eventMonitor.addLocalKeyDownMonitor { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = GlobalShortcutCatalog.normalizedModifiers(event.modifierFlags)
            let timestamp = event.timestamp
            let isARepeat = event.isARepeat
            Task { @MainActor [weak self] in
                self?.handle(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    timestamp: timestamp,
                    isARepeat: isARepeat
                )
            }
            return event
        }
        isRunning = globalMonitor != nil || localMonitor != nil
    }

    func stop() {
        if let globalMonitor { eventMonitor.removeMonitor(globalMonitor) }
        if let localMonitor { eventMonitor.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        eventGate.reset()
        isRunning = false
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    func binding(for layout: WindowLayout) -> GlobalShortcut? {
        bindings[layout]
    }

    func setBinding(_ binding: GlobalShortcut, for layout: WindowLayout) throws {
        guard binding.modifiers & GlobalShortcutModifier.relevantMask != 0 else {
            throw WindowShortcutError.modifierRequired
        }
        if let conflict = WindowShortcutCatalog.conflict(for: binding, excluding: layout, in: bindings) {
            throw WindowShortcutError.conflict(conflict)
        }
        if quickAccessBinding == binding {
            throw WindowShortcutError.conflict(layout)
        }
        if let conflict = presetShortcuts.first(where: { $0.shortcut == binding }) {
            throw WindowShortcutError.presetConflict(conflict.name)
        }
        let context = ShortcutConflictContext(
            sceneBindings: sceneBindingsProvider(),
            windowBindings: bindings,
            appBindings: appBindingsProvider(),
            screenshotBindings: screenshotBindingsProvider(),
            clipboardBinding: clipboardBindingProvider(),
            appVolumeBinding: appVolumeBindingProvider(),
            excludingScene: nil,
            excludingWindow: layout,
            excludingAppPath: nil,
            excludingScreenshotMode: nil,
            excludingClipboard: false,
            excludingAppVolume: false,
            windowQuickAccessBinding: quickAccessBinding,
            windowPresetBindings: presetShortcuts
        )
        try validateWithSharedChecker(binding, context: context)
        bindings[layout] = binding
        lastError = nil
        saveBindings()
    }

    /// 配置用于直接打开窗口管理面板的全局快捷键。
    func setQuickAccessBinding(_ binding: GlobalShortcut) throws {
        guard binding.modifiers & GlobalShortcutModifier.relevantMask != 0 else {
            throw WindowShortcutError.modifierRequired
        }
        if let conflict = bindings.first(where: { $0.value == binding })?.key {
            throw WindowShortcutError.conflict(conflict)
        }
        if let conflict = presetShortcuts.first(where: { $0.shortcut == binding }) {
            throw WindowShortcutError.presetConflict(conflict.name)
        }
        let context = ShortcutConflictContext(
            sceneBindings: sceneBindingsProvider(),
            windowBindings: bindings,
            appBindings: appBindingsProvider(),
            screenshotBindings: screenshotBindingsProvider(),
            clipboardBinding: clipboardBindingProvider(),
            appVolumeBinding: appVolumeBindingProvider(),
            excludingScene: nil,
            excludingWindow: nil,
            excludingAppPath: nil,
            excludingScreenshotMode: nil,
            excludingClipboard: false,
            excludingAppVolume: false,
            windowQuickAccessBinding: quickAccessBinding,
            excludingWindowQuickAccess: true,
            windowPresetBindings: presetShortcuts
        )
        try validateWithSharedChecker(binding, context: context)
        quickAccessBinding = binding
        lastError = nil
        saveQuickAccessBinding()
    }

    func clearBinding(for layout: WindowLayout) {
        bindings.removeValue(forKey: layout)
        lastError = nil
        saveBindings()
    }

    func presetBinding(for presetID: UUID) -> GlobalShortcut? {
        presetShortcuts.first { $0.id == presetID }?.shortcut
    }

    /// 给固定尺寸预设绑定全局快捷键；与布局、其他预设、快速面板快捷键互斥。
    func setPresetBinding(_ binding: GlobalShortcut, for preset: WindowLayoutPreset) throws {
        guard binding.modifiers & GlobalShortcutModifier.relevantMask != 0 else {
            throw WindowShortcutError.modifierRequired
        }
        if let conflict = bindings.first(where: { $0.value == binding })?.key {
            throw WindowShortcutError.conflict(conflict)
        }
        if let conflict = presetShortcuts.first(where: { $0.id != preset.id && $0.shortcut == binding }) {
            throw WindowShortcutError.presetConflict(conflict.name)
        }
        if quickAccessBinding == binding {
            throw WindowShortcutError.quickAccessConflict
        }
        try validateWithSharedChecker(
            binding,
            context: ShortcutConflictContext(
                sceneBindings: sceneBindingsProvider(),
                windowBindings: bindings,
                appBindings: appBindingsProvider(),
                screenshotBindings: screenshotBindingsProvider(),
                clipboardBinding: clipboardBindingProvider(),
                appVolumeBinding: appVolumeBindingProvider(),
                excludingScene: nil,
                excludingWindow: nil,
                excludingAppPath: nil,
                excludingScreenshotMode: nil,
                excludingClipboard: false,
                excludingAppVolume: false,
                windowQuickAccessBinding: quickAccessBinding,
                windowPresetBindings: presetShortcuts,
                excludingWindowPreset: preset.id
            )
        )

        let record = WindowPresetShortcut(id: preset.id, name: preset.name, shortcut: binding)
        if let index = presetShortcuts.firstIndex(where: { $0.id == preset.id }) {
            presetShortcuts[index] = record
        } else {
            presetShortcuts.append(record)
        }
        lastError = nil
        savePresetShortcuts()
    }

    func clearPresetBinding(for presetID: UUID) {
        presetShortcuts.removeAll { $0.id == presetID }
        lastError = nil
        savePresetShortcuts()
    }

    /// 预设被删除后不再保留它的快捷键绑定。
    func prunePresetBindings(keeping presetIDs: Set<UUID>) {
        let kept = presetShortcuts.filter { presetIDs.contains($0.id) }
        guard kept.count != presetShortcuts.count else { return }
        presetShortcuts = kept
        savePresetShortcuts()
    }

    /// 把共享冲突检测器的结果翻译成窗口模块自己的错误。
    private func validateWithSharedChecker(
        _ binding: GlobalShortcut,
        context: ShortcutConflictContext
    ) throws {
        switch conflictChecker.conflict(for: binding, context: context) {
        case .system:
            throw WindowShortcutError.systemConflict
        case .otherApplication:
            throw WindowShortcutError.otherApplicationConflict
        case let .scene(scene):
            throw WindowShortcutError.sceneConflict(scene)
        case let .window(conflict):
            throw WindowShortcutError.conflict(conflict)
        case let .windowPreset(name):
            throw WindowShortcutError.presetConflict(name)
        case .windowManagement:
            throw WindowShortcutError.quickAccessConflict
        case let .app(path):
            throw WindowShortcutError.appConflict(path)
        case .screenshot:
            throw WindowShortcutError.screenshotConflict
        case .clipboard:
            throw WindowShortcutError.clipboardConflict
        case .appVolume:
            throw WindowShortcutError.appVolumeConflict
        case .translation:
            throw WindowShortcutError.translationConflict
        case nil:
            break
        }
    }

    func clearQuickAccessBinding() {
        quickAccessBinding = nil
        lastError = nil
        defaults.removeObject(forKey: Self.quickAccessBindingKey)
    }

    private func handle(
        keyCode: UInt16,
        modifiers: UInt,
        timestamp: TimeInterval,
        isARepeat: Bool
    ) {
        guard eventGate.accept(
            keyCode: keyCode,
            modifiers: modifiers,
            timestamp: timestamp,
            isARepeat: isARepeat
        ) else { return }
        if quickAccessBinding?.keyCode == keyCode, quickAccessBinding?.modifiers == modifiers {
            // 在显示 MenuTools 的界面前记录目标，面板点击时仍操作此前的外部前台应用。
            prepareQuickAccessTarget()
            onQuickAccessTrigger()
            lastError = nil
            return
        }
        // 预设快捷键在布局快捷键之后匹配：两者已在绑定时互斥。
        if let presetID = WindowShortcutCatalog.matchPreset(
            keyCode: keyCode,
            modifiers: modifiers,
            bindings: presetShortcuts
        ) {
            guard let preset = WindowManagementService.shared.configuration.presets.first(where: { $0.id == presetID }) else {
                // 预设已被删除：顺手清掉悬空的绑定，避免占着快捷键。
                clearPresetBinding(for: presetID)
                return
            }
            do {
                try WindowManagementService.shared.apply(preset)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            return
        }
        guard let layout = WindowShortcutCatalog.match(
            keyCode: keyCode,
            modifiers: modifiers,
            bindings: bindings
        ) else {
            return
        }

        do {
            try WindowManagementService.shared.apply(layout)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func savePresetShortcuts() {
        guard let data = try? JSONEncoder().encode(presetShortcuts) else { return }
        defaults.set(data, forKey: Self.presetShortcutsKey)
    }

    private static func loadPresetShortcuts(from defaults: UserDefaults) -> [WindowPresetShortcut] {
        guard let data = defaults.data(forKey: presetShortcutsKey),
              let values = try? JSONDecoder().decode([WindowPresetShortcut].self, from: data) else {
            return []
        }
        return values
    }

    private func saveBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Self.bindingsKey)
    }

    private static let bindingsKey = "windowManagement.shortcuts"
    private static let quickAccessBindingKey = "windowManagement.quickAccessShortcut"
    private static let presetShortcutsKey = "windowManagement.presetShortcuts"

    private static func loadBindings(from defaults: UserDefaults) -> [WindowLayout: GlobalShortcut] {
        guard let data = defaults.data(forKey: bindingsKey),
              let values = try? JSONDecoder().decode([WindowLayout: GlobalShortcut].self, from: data) else {
            return [:]
        }
        return values
    }

    private func saveQuickAccessBinding() {
        guard let quickAccessBinding,
              let data = try? JSONEncoder().encode(quickAccessBinding) else { return }
        defaults.set(data, forKey: Self.quickAccessBindingKey)
    }

    private static func loadQuickAccessBinding(from defaults: UserDefaults) -> GlobalShortcut? {
        guard let data = defaults.data(forKey: quickAccessBindingKey) else { return nil }
        return try? JSONDecoder().decode(GlobalShortcut.self, from: data)
    }
}
