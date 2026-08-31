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

enum AppVolumeShortcutError: LocalizedError, Equatable {
    case modifierRequired
    case systemConflict
    case otherApplicationConflict
    case sceneConflict(ScenePreset)
    case windowConflict(WindowLayout)
    case appConflict(String)
    case screenshotConflict
    case clipboardConflict

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
        case let .appConflict(path):
            return L(
                "shortcut.error.conflict",
                URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            )
        case .screenshotConflict:
            return L("shortcut.error.screenshotConflict")
        case .clipboardConflict:
            return L("shortcut.error.conflict", L("settings.tab.clipboard"))
        }
    }
}

/// App 音量管理的全局快捷键，插件停用时不会保留事件监听。
@MainActor
@Observable
final class AppVolumeShortcutService {
    static let shared = AppVolumeShortcutService()

    private static let bindingKey = "appVolumeShortcut.binding"

    private(set) var binding: GlobalShortcut?
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
        onTrigger: @escaping @MainActor () -> Void = { MenuBarStatusItemController.shared.showAppVolume() }
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
        binding = Self.loadBinding(from: defaults)
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
        guard newBinding.modifiers & GlobalShortcutModifier.relevantMask != 0 else {
            throw AppVolumeShortcutError.modifierRequired
        }
        let context = ShortcutConflictContext(
            sceneBindings: sceneBindingsProvider(),
            windowBindings: windowBindingsProvider(),
            appBindings: appBindingsProvider(),
            screenshotBindings: screenshotBindingsProvider(),
            clipboardBinding: clipboardBindingProvider(),
            appVolumeBinding: binding,
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
        case let .app(path):
            throw AppVolumeShortcutError.appConflict(path)
        case .screenshot:
            throw AppVolumeShortcutError.screenshotConflict
        case .clipboard:
            throw AppVolumeShortcutError.clipboardConflict
        case .appVolume, nil:
            break
        }
        binding = newBinding
        lastError = nil
        saveBinding()
    }

    func clearBinding() {
        binding = nil
        lastError = nil
        defaults.removeObject(forKey: Self.bindingKey)
    }

    private func handle(
        keyCode: UInt16,
        modifiers: UInt,
        timestamp: TimeInterval,
        isARepeat: Bool
    ) {
        guard AppVolumeShortcutCatalog.matches(keyCode: keyCode, modifiers: modifiers, binding: binding) else {
            return
        }
        guard eventGate.accept(
            keyCode: keyCode,
            modifiers: modifiers,
            timestamp: timestamp,
            isARepeat: isARepeat
        ) else { return }
        onTrigger()
    }

    private func saveBinding() {
        guard let binding, let data = try? JSONEncoder().encode(binding) else { return }
        defaults.set(data, forKey: Self.bindingKey)
    }

    private static func loadBinding(from defaults: UserDefaults) -> GlobalShortcut? {
        guard let data = defaults.data(forKey: bindingKey) else { return nil }
        return try? JSONDecoder().decode(GlobalShortcut.self, from: data)
    }
}
