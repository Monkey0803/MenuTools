import AppKit
import ApplicationServices
import Foundation
import Observation

enum TranslationShortcutCatalog {
    static func matches(keyCode: UInt16, modifiers: UInt, binding: GlobalShortcut?) -> Bool {
        binding?.keyCode == keyCode && binding?.modifiers == modifiers
    }
}

enum TranslationShortcutError: LocalizedError, Equatable {
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
    case appVolumeConflict

    var errorDescription: String? {
        switch self {
        case .modifierRequired: return L("shortcut.error.modifierRequired")
        case .systemConflict: return L("shortcut.error.systemConflict")
        case .otherApplicationConflict: return L("shortcut.error.otherApplicationConflict")
        case let .sceneConflict(scene): return L("shortcut.error.conflict", L(scene.titleKey))
        case let .windowConflict(layout): return L("shortcut.error.conflict", L(layout.titleKey))
        case let .windowPresetConflict(name): return L("shortcut.error.windowPresetConflict", name)
        case .windowManagementConflict: return L("shortcut.error.conflict", L("window.title"))
        case let .appConflict(path):
            return L("shortcut.error.conflict", URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        case .screenshotConflict: return L("shortcut.error.screenshotConflict")
        case .clipboardConflict: return L("shortcut.error.conflict", L("settings.tab.clipboard"))
        case .appVolumeConflict: return L("shortcut.error.conflict", L("settings.tab.volume"))
        }
    }
}

/// 翻译窗口的全局快捷键，确保菜单栏面板关闭后仍可从任意应用唤起。
@MainActor
@Observable
final class TranslationShortcutService {
    static let shared = TranslationShortcutService()

    private static let bindingKey = "translationShortcut.binding"

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
        clipboardBindingProvider: @escaping @MainActor () -> GlobalShortcut? = { ClipboardShortcutService.shared.binding },
        appVolumeBindingProvider: @escaping @MainActor () -> GlobalShortcut? = { AppVolumeShortcutService.shared.binding },
        onTrigger: @escaping @MainActor () -> Void = { TranslationWindowController.shared.showFromClipboard() }
    ) {
        self.defaults = defaults
        self.conflictChecker = conflictChecker
        self.sceneBindingsProvider = sceneBindingsProvider
        self.windowBindingsProvider = windowBindingsProvider
        self.appBindingsProvider = appBindingsProvider
        self.screenshotBindingsProvider = screenshotBindingsProvider
        self.clipboardBindingProvider = clipboardBindingProvider
        self.appVolumeBindingProvider = appVolumeBindingProvider
        self.onTrigger = onTrigger
        binding = Self.loadBinding(from: defaults)
    }

    func start() {
        guard globalMonitor == nil && localMonitor == nil else { return }
        isAccessibilityTrusted = AXIsProcessTrusted()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.enqueue(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.enqueue(event)
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
            throw TranslationShortcutError.modifierRequired
        }
        let context = ShortcutConflictContext(
            sceneBindings: sceneBindingsProvider(),
            windowBindings: windowBindingsProvider(),
            appBindings: appBindingsProvider(),
            screenshotBindings: screenshotBindingsProvider(),
            clipboardBinding: clipboardBindingProvider(),
            appVolumeBinding: appVolumeBindingProvider(),
            excludingScene: nil,
            excludingWindow: nil,
            excludingAppPath: nil,
            excludingScreenshotMode: nil,
            excludingClipboard: false,
            excludingAppVolume: false
        )
        switch conflictChecker.conflict(for: newBinding, context: context) {
        case .system: throw TranslationShortcutError.systemConflict
        case .otherApplication: throw TranslationShortcutError.otherApplicationConflict
        case let .scene(scene): throw TranslationShortcutError.sceneConflict(scene)
        case let .window(layout): throw TranslationShortcutError.windowConflict(layout)
        case let .windowPreset(name): throw TranslationShortcutError.windowPresetConflict(name)
        case .windowManagement: throw TranslationShortcutError.windowManagementConflict
        case let .app(path): throw TranslationShortcutError.appConflict(path)
        case .screenshot: throw TranslationShortcutError.screenshotConflict
        case .clipboard: throw TranslationShortcutError.clipboardConflict
        case .appVolume: throw TranslationShortcutError.appVolumeConflict
        case .translation, nil: break
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

    private nonisolated func enqueue(_ event: NSEvent) {
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

    private func handle(keyCode: UInt16, modifiers: UInt, timestamp: TimeInterval, isARepeat: Bool) {
        guard TranslationShortcutCatalog.matches(keyCode: keyCode, modifiers: modifiers, binding: binding),
              eventGate.accept(keyCode: keyCode, modifiers: modifiers, timestamp: timestamp, isARepeat: isARepeat) else {
            return
        }
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
