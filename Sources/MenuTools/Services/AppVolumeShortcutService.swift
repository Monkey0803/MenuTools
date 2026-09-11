import AppKit
import ApplicationServices
import Foundation
import Observation

enum AppVolumeShortcutCatalog {
    static func matches(
        keyCode: UInt16,
        modifiers: UInt,
        binding: GlobalShortcut?
    ) -> Bool {
        binding?.keyCode == keyCode && binding?.modifiers == modifiers
    }
}

enum AppVolumeShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case showPanel
    case increase
    case decrease
    case toggleMute

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .showPanel: "volume.shortcut.showPanel"
        case .increase: "volume.shortcut.increase"
        case .decrease: "volume.shortcut.decrease"
        case .toggleMute: "volume.shortcut.toggleMute"
        }
    }
}

@MainActor
protocol AppVolumeShortcutEventMonitoring: AnyObject {
    func addGlobalKeyDownMonitor(_ handler: @escaping (NSEvent) -> Void) -> Any?
    func addLocalKeyDownMonitor(_ handler: @escaping (NSEvent) -> NSEvent?) -> Any?
    func removeMonitor(_ monitor: Any)
}

@MainActor
final class DefaultAppVolumeShortcutEventMonitor: AppVolumeShortcutEventMonitoring {
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

struct AppVolumeShortcutEventGate {
    private(set) var lastEvent: (keyCode: UInt16, modifiers: UInt, timestamp: TimeInterval)?

    mutating func accept(
        keyCode: UInt16,
        modifiers: UInt,
        timestamp: TimeInterval,
        isARepeat: Bool,
        allowsRepeat: Bool = false
    ) -> Bool {
        guard !isARepeat || allowsRepeat else { return false }
        guard let lastEvent else {
            self.lastEvent = (keyCode, modifiers, timestamp)
            return true
        }
        guard lastEvent.keyCode == keyCode,
              lastEvent.modifiers == modifiers else {
            self.lastEvent = (keyCode, modifiers, timestamp)
            return true
        }
        guard timestamp - lastEvent.timestamp > (allowsRepeat ? 0.05 : 0.35) else { return false }
        self.lastEvent = (keyCode, modifiers, timestamp)
        return true
    }

    mutating func reset() {
        lastEvent = nil
    }
}

enum AppVolumeShortcutError: LocalizedError, Equatable {
    case modifierRequired
    case systemConflict
    case otherApplicationConflict
    case sceneConflict(ScenePreset)
    case windowConflict(WindowLayout)
    case windowPresetConflict(String)
    case windowManagementConflict
    case appConflict(String)
    case screenshotConflict
    case clipboardConflict
    case translationConflict
    case appVolumeConflict
    case duplicateBinding

    var errorDescription: String? {
        switch self {
        case .modifierRequired:
            return L("shortcut.error.modifierRequired")
        case .systemConflict:
            return L("shortcut.error.systemConflict")
        case .otherApplicationConflict:
            return L("shortcut.error.otherApplicationConflict")
        case let .sceneConflict(scene):
            return L("shortcut.error.conflict", L(scene.titleKey))
        case let .windowConflict(layout):
            return L("shortcut.error.conflict", L(layout.titleKey))
        case let .windowPresetConflict(name):
            return L("shortcut.error.windowPresetConflict", name)
        case .windowManagementConflict:
            return L("shortcut.error.conflict", L("window.title"))
        case let .appConflict(path):
            return L(
                "shortcut.error.conflict",
                URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            )
        case .screenshotConflict:
            return L("shortcut.error.screenshotConflict")
        case .clipboardConflict:
            return L("shortcut.error.conflict", L("settings.tab.clipboard"))
        case .translationConflict:
            return L("shortcut.error.conflict", L("settings.tab.translation"))
        case .appVolumeConflict:
            return L("shortcut.error.conflict", L("settings.tab.volume"))
        case .duplicateBinding:
            return L("shortcut.error.conflict", L("volume.title"))
        }
    }
}

/// App 音量管理的全局快捷键，插件停用时不会保留事件监听。
@MainActor
@Observable
final class AppVolumeShortcutService {
    static let shared = AppVolumeShortcutService()

    private static let bindingKey = "appVolumeShortcut.binding"
    private static let bindingsKey = "appVolumeShortcut.bindings.v2"

    private(set) var bindings: [AppVolumeShortcutAction: GlobalShortcut]
    var binding: GlobalShortcut? { bindings[.showPanel] }
    private(set) var lastError: String?
    private(set) var isRunning = false
    private(set) var isAccessibilityTrusted = AXIsProcessTrusted()

    private let defaults: UserDefaults
    private let conflictChecker: any ShortcutConflictChecking
    private let sceneBindingsProvider: @MainActor () -> [ScenePreset: GlobalShortcut]
    private let windowBindingsProvider: @MainActor () -> [WindowLayout: GlobalShortcut]
    private let appBindingsProvider: @MainActor () -> [String: GlobalShortcut]
    private let screenshotBindingsProvider: @MainActor () -> [ScreenshotCaptureMode: GlobalShortcut]
    private let clipboardBindingProvider: @MainActor () -> GlobalShortcut?
    private let eventMonitor: any AppVolumeShortcutEventMonitoring
    private let onTrigger: @MainActor () -> Void
    private let onAction: (@MainActor (AppVolumeShortcutAction) -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventGate = AppVolumeShortcutEventGate()

    init(
        defaults: UserDefaults = .standard,
        conflictChecker: any ShortcutConflictChecking = DefaultShortcutConflictChecker(),
        sceneBindingsProvider: @escaping @MainActor () -> [ScenePreset: GlobalShortcut] = { GlobalShortcutService.shared.bindings },
        windowBindingsProvider: @escaping @MainActor () -> [WindowLayout: GlobalShortcut] = { WindowShortcutService.shared.bindings },
        appBindingsProvider: @escaping @MainActor () -> [String: GlobalShortcut] = { AppShortcutService.shared.bindings },
        screenshotBindingsProvider: @escaping @MainActor () -> [ScreenshotCaptureMode: GlobalShortcut] = { ScreenshotShortcutService.shared.bindings },
        clipboardBindingProvider: @escaping @MainActor () -> GlobalShortcut? = { ClipboardShortcutService.shared.binding },
        eventMonitor: any AppVolumeShortcutEventMonitoring = DefaultAppVolumeShortcutEventMonitor(),
        onTrigger: @escaping @MainActor () -> Void = { MenuBarStatusItemController.shared.showAppVolume() },
        onAction: (@MainActor (AppVolumeShortcutAction) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.conflictChecker = conflictChecker
        self.sceneBindingsProvider = sceneBindingsProvider
        self.windowBindingsProvider = windowBindingsProvider
        self.appBindingsProvider = appBindingsProvider
        self.screenshotBindingsProvider = screenshotBindingsProvider
        self.clipboardBindingProvider = clipboardBindingProvider
        self.eventMonitor = eventMonitor
        self.onTrigger = onTrigger
        self.onAction = onAction
        bindings = Self.loadBindings(from: defaults)
    }

    func start() {
        guard globalMonitor == nil && localMonitor == nil else { return }
        refreshAccessibilityTrust()
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
        refreshAccessibilityTrust()
    }

    func refreshAccessibilityTrust() {
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    func setBinding(_ newBinding: GlobalShortcut) throws {
        try setBinding(newBinding, for: .showPanel)
    }

    func setBinding(_ newBinding: GlobalShortcut, for action: AppVolumeShortcutAction) throws {
        guard newBinding.modifiers & GlobalShortcutModifier.relevantMask != 0 else {
            throw AppVolumeShortcutError.modifierRequired
        }
        guard !bindings.contains(where: { $0.key != action && $0.value == newBinding }) else {
            throw AppVolumeShortcutError.duplicateBinding
        }
        let context = ShortcutConflictContext(
            sceneBindings: sceneBindingsProvider(),
            windowBindings: windowBindingsProvider(),
            appBindings: appBindingsProvider(),
            screenshotBindings: screenshotBindingsProvider(),
            clipboardBinding: clipboardBindingProvider(),
            appVolumeBinding: bindings.first(where: { $0.key != action })?.value,
            excludingScene: nil,
            excludingWindow: nil,
            excludingAppPath: nil,
            excludingScreenshotMode: nil,
            excludingClipboard: false,
            excludingAppVolume: true
        )
        switch conflictChecker.conflict(for: newBinding, context: context) {
        case .system:
            throw AppVolumeShortcutError.systemConflict
        case .otherApplication:
            throw AppVolumeShortcutError.otherApplicationConflict
        case let .scene(scene):
            throw AppVolumeShortcutError.sceneConflict(scene)
        case let .window(layout):
            throw AppVolumeShortcutError.windowConflict(layout)
        case let .windowPreset(name):
            throw AppVolumeShortcutError.windowPresetConflict(name)
        case .windowManagement:
            throw AppVolumeShortcutError.windowManagementConflict
        case let .app(path):
            throw AppVolumeShortcutError.appConflict(path)
        case .screenshot:
            throw AppVolumeShortcutError.screenshotConflict
        case .clipboard:
            throw AppVolumeShortcutError.clipboardConflict
        case .translation:
            throw AppVolumeShortcutError.translationConflict
        case .appVolume, nil:
            break
        }
        bindings[action] = newBinding
        lastError = nil
        saveBindings()
    }

    func clearBinding() {
        clearBinding(for: .showPanel)
    }

    func clearBinding(for action: AppVolumeShortcutAction) {
        bindings.removeValue(forKey: action)
        lastError = nil
        saveBindings()
    }

    private func handle(
        keyCode: UInt16,
        modifiers: UInt,
        timestamp: TimeInterval,
        isARepeat: Bool
    ) {
        guard let action = bindings.first(where: {
            AppVolumeShortcutCatalog.matches(keyCode: keyCode, modifiers: modifiers, binding: $0.value)
        })?.key else {
            return
        }
        guard eventGate.accept(
            keyCode: keyCode,
            modifiers: modifiers,
            timestamp: timestamp,
            isARepeat: isARepeat,
            allowsRepeat: action == .increase || action == .decrease
        ) else { return }
        if action == .showPanel {
            onTrigger()
        } else if let onAction {
            onAction(action)
        } else {
            performDefaultAction(action)
        }
    }

    private func performDefaultAction(_ action: AppVolumeShortcutAction) {
        switch action {
        case .showPanel:
            onTrigger()
        case .increase:
            let service = AppVolumeService.shared
            service.adjustMasterVolume(increase: true)
            AppVolumeHUDController.shared.show(volume: service.output.volume, isMuted: service.output.isMuted)
        case .decrease:
            let service = AppVolumeService.shared
            service.adjustMasterVolume(increase: false)
            AppVolumeHUDController.shared.show(volume: service.output.volume, isMuted: service.output.isMuted)
        case .toggleMute:
            let service = AppVolumeService.shared
            service.setMasterMuted(!service.output.isMuted)
            AppVolumeHUDController.shared.show(volume: service.output.volume, isMuted: service.output.isMuted)
        }
    }

    private func saveBindings() {
        if bindings.isEmpty {
            defaults.removeObject(forKey: Self.bindingsKey)
            defaults.removeObject(forKey: Self.bindingKey)
            return
        }
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Self.bindingsKey)
        defaults.removeObject(forKey: Self.bindingKey)
    }

    private static func loadBindings(from defaults: UserDefaults) -> [AppVolumeShortcutAction: GlobalShortcut] {
        if let data = defaults.data(forKey: bindingsKey),
           let bindings = try? JSONDecoder().decode([AppVolumeShortcutAction: GlobalShortcut].self, from: data) {
            return bindings
        }
        guard let data = defaults.data(forKey: bindingKey),
              let binding = try? JSONDecoder().decode(GlobalShortcut.self, from: data) else {
            return [:]
        }
        return [.showPanel: binding]
    }
}
