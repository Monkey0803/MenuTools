import AppKit
import ApplicationServices
import Foundation
import Observation

enum ClipboardShortcutCatalog {
    static func matches(
        keyCode: UInt16,
        modifiers: UInt,
        binding: GlobalShortcut?
    ) -> Bool {
        binding?.keyCode == keyCode && binding?.modifiers == modifiers
    }
}

struct ClipboardShortcutEventGate {
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

enum ClipboardShortcutError: LocalizedError, Equatable {
    case modifierRequired
    case systemConflict
    case otherApplicationConflict
    case sceneConflict(ScenePreset)
    case windowConflict(WindowLayout)
    case appConflict(String)
    case screenshotConflict
    case appVolumeConflict

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
        case .appVolumeConflict:
            return L("shortcut.error.conflict", L("settings.tab.volume"))
        }
    }
}

/// 剪贴板历史的全局快捷键，插件停用时不会保留事件监听。
@MainActor
@Observable
final class ClipboardShortcutService {
    static let shared = ClipboardShortcutService()

    private static let bindingKey = "clipboardShortcut.binding"

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
    private let appVolumeBindingProvider: @MainActor () -> GlobalShortcut?
    private let onTrigger: @MainActor () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventGate = ClipboardShortcutEventGate()

    init(
        defaults: UserDefaults = .standard,
        conflictChecker: any ShortcutConflictChecking = DefaultShortcutConflictChecker(),
        sceneBindingsProvider: @escaping @MainActor () -> [ScenePreset: GlobalShortcut] = { GlobalShortcutService.shared.bindings },
        windowBindingsProvider: @escaping @MainActor () -> [WindowLayout: GlobalShortcut] = { WindowShortcutService.shared.bindings },
        appBindingsProvider: @escaping @MainActor () -> [String: GlobalShortcut] = { AppShortcutService.shared.bindings },
        screenshotBindingsProvider: @escaping @MainActor () -> [ScreenshotCaptureMode: GlobalShortcut] = { ScreenshotShortcutService.shared.bindings },
        appVolumeBindingProvider: @escaping @MainActor () -> GlobalShortcut? = { AppVolumeShortcutService.shared.binding },
        onTrigger: @escaping @MainActor () -> Void = { MenuBarStatusItemController.shared.showClipboardHistory() }
    ) {
        self.defaults = defaults
        self.conflictChecker = conflictChecker
        self.sceneBindingsProvider = sceneBindingsProvider
        self.windowBindingsProvider = windowBindingsProvider
        self.appBindingsProvider = appBindingsProvider
        self.screenshotBindingsProvider = screenshotBindingsProvider
        self.appVolumeBindingProvider = appVolumeBindingProvider
        self.onTrigger = onTrigger
        binding = Self.loadBinding(from: defaults)
    }

    func start() {
        guard globalMonitor == nil && localMonitor == nil else { return }
        isAccessibilityTrusted = AXIsProcessTrusted()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        eventGate.reset()
        isRunning = false
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    func setBinding(_ newBinding: GlobalShortcut) throws {
        guard newBinding.modifiers & GlobalShortcutModifier.relevantMask != 0 else {
            throw ClipboardShortcutError.modifierRequired
        }
        let context = ShortcutConflictContext(
            sceneBindings: sceneBindingsProvider(),
            windowBindings: windowBindingsProvider(),
            appBindings: appBindingsProvider(),
            screenshotBindings: screenshotBindingsProvider(),
            clipboardBinding: binding,
            appVolumeBinding: appVolumeBindingProvider(),
            excludingScene: nil,
            excludingWindow: nil,
            excludingAppPath: nil,
            excludingScreenshotMode: nil,
            excludingClipboard: true,
            excludingAppVolume: false
        )
        switch conflictChecker.conflict(for: newBinding, context: context) {
        case .system:
            throw ClipboardShortcutError.systemConflict
        case .otherApplication:
            throw ClipboardShortcutError.otherApplicationConflict
        case let .scene(scene):
            throw ClipboardShortcutError.sceneConflict(scene)
        case let .window(layout):
            throw ClipboardShortcutError.windowConflict(layout)
        case let .app(path):
            throw ClipboardShortcutError.appConflict(path)
        case .screenshot:
            throw ClipboardShortcutError.screenshotConflict
        case .appVolume:
            throw ClipboardShortcutError.appVolumeConflict
        case .clipboard, nil:
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
        guard ClipboardShortcutCatalog.matches(keyCode: keyCode, modifiers: modifiers, binding: binding) else {
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
