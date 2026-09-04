import AppKit
import ApplicationServices
import Foundation
import Observation

enum AppShortcutCatalog {
    static func match(
        keyCode: UInt16,
        modifiers: UInt,
        bindings: [String: GlobalShortcut]
    ) -> String? {
        bindings.first {
            $0.value.keyCode == keyCode && $0.value.modifiers == modifiers
        }?.key
    }

    static func conflict(
        for binding: GlobalShortcut,
        excluding path: String,
        in bindings: [String: GlobalShortcut]
    ) -> String? {
        bindings.first { $0.key != path && $0.value == binding }?.key
    }
}

enum AppShortcutError: LocalizedError, Equatable {
    case modifierRequired
    case conflict(String)
    case systemConflict
    case otherApplicationConflict
    case sceneConflict(ScenePreset)
    case windowConflict(WindowLayout)
    case windowManagementConflict
    case screenshotConflict
    case clipboardConflict
    case appVolumeConflict
    case translationConflict
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .modifierRequired:
            return L("shortcut.error.modifierRequired")
        case let .conflict(path):
            return L(
                "shortcut.error.conflict",
                URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            )
        case .systemConflict:
            return L("shortcut.error.systemConflict")
        case .otherApplicationConflict:
            return L("shortcut.error.otherApplicationConflict")
        case let .sceneConflict(scene):
            return L("shortcut.error.conflict", L(scene.titleKey))
        case let .windowConflict(layout):
            return L("shortcut.error.conflict", L(layout.titleKey))
        case .windowManagementConflict:
            return L("shortcut.error.conflict", L("window.title"))
        case .screenshotConflict:
            return L("shortcut.error.screenshotConflict")
        case .clipboardConflict:
            return L("shortcut.error.conflict", L("settings.tab.clipboard"))
        case .appVolumeConflict:
            return L("shortcut.error.conflict", L("settings.tab.volume"))
        case .translationConflict:
            return L("shortcut.error.conflict", L("settings.tab.translation"))
        case let .launchFailed(name):
            return L("appShortcut.launchFailed", name)
        }
    }
}

/// 应用快捷键服务，独立于设置窗口持续监听并启动指定应用。
@MainActor
@Observable
final class AppShortcutService {
    static let shared = AppShortcutService()

    private(set) var bindings: [String: GlobalShortcut]
    private(set) var lastTriggeredPath: String?
    private(set) var lastError: String?
    private(set) var isRunning = false
    private(set) var isAccessibilityTrusted = AXIsProcessTrusted()

    private let defaults: UserDefaults
    private let launcher: AppLauncherService
    private let conflictChecker: any ShortcutConflictChecking
    private let sceneBindingsProvider: @MainActor () -> [ScenePreset: GlobalShortcut]
    private let windowBindingsProvider: @MainActor () -> [WindowLayout: GlobalShortcut]
    private let screenshotBindingsProvider: @MainActor () -> [ScreenshotCaptureMode: GlobalShortcut]
    private let clipboardBindingProvider: @MainActor () -> GlobalShortcut?
    private let appVolumeBindingProvider: @MainActor () -> GlobalShortcut?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(
        defaults: UserDefaults = .standard,
        launcher: AppLauncherService = .shared,
        conflictChecker: any ShortcutConflictChecking = DefaultShortcutConflictChecker(),
        sceneBindingsProvider: @escaping @MainActor () -> [ScenePreset: GlobalShortcut] = { GlobalShortcutService.shared.bindings },
        windowBindingsProvider: @escaping @MainActor () -> [WindowLayout: GlobalShortcut] = { WindowShortcutService.shared.bindings },
        screenshotBindingsProvider: @escaping @MainActor () -> [ScreenshotCaptureMode: GlobalShortcut] = { ScreenshotShortcutService.shared.bindings },
        clipboardBindingProvider: @escaping @MainActor () -> GlobalShortcut? = { ClipboardShortcutService.shared.binding },
        appVolumeBindingProvider: @escaping @MainActor () -> GlobalShortcut? = { AppVolumeShortcutService.shared.binding }
    ) {
        self.defaults = defaults
        self.launcher = launcher
        self.conflictChecker = conflictChecker
        self.sceneBindingsProvider = sceneBindingsProvider
        self.windowBindingsProvider = windowBindingsProvider
        self.screenshotBindingsProvider = screenshotBindingsProvider
        self.clipboardBindingProvider = clipboardBindingProvider
        self.appVolumeBindingProvider = appVolumeBindingProvider
        self.bindings = Self.loadBindings(from: defaults)
    }

    func start() {
        guard globalMonitor == nil && localMonitor == nil else { return }
        isAccessibilityTrusted = AXIsProcessTrusted()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = GlobalShortcutCatalog.normalizedModifiers(event.modifierFlags)
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, modifiers: modifiers)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = GlobalShortcutCatalog.normalizedModifiers(event.modifierFlags)
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, modifiers: modifiers)
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
        isRunning = false
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    func binding(for app: LaunchableApp) -> GlobalShortcut? {
        bindings[app.path]
    }

    func binding(for path: String) -> GlobalShortcut? {
        bindings[path]
    }

    func setBinding(_ binding: GlobalShortcut, for app: LaunchableApp) throws {
        guard binding.modifiers & GlobalShortcutModifier.relevantMask != 0 else {
            throw AppShortcutError.modifierRequired
        }
        if let conflict = AppShortcutCatalog.conflict(for: binding, excluding: app.path, in: bindings) {
            throw AppShortcutError.conflict(conflict)
        }

        let context = ShortcutConflictContext(
            sceneBindings: sceneBindingsProvider(),
            windowBindings: windowBindingsProvider(),
            appBindings: bindings,
            screenshotBindings: screenshotBindingsProvider(),
            clipboardBinding: clipboardBindingProvider(),
            appVolumeBinding: appVolumeBindingProvider(),
            excludingScene: nil,
            excludingWindow: nil,
            excludingAppPath: app.path,
            excludingScreenshotMode: nil,
            excludingClipboard: false,
            excludingAppVolume: false
        )
        switch conflictChecker.conflict(for: binding, context: context) {
        case .system:
            throw AppShortcutError.systemConflict
        case .otherApplication:
            throw AppShortcutError.otherApplicationConflict
        case let .scene(scene):
            throw AppShortcutError.sceneConflict(scene)
        case let .window(layout):
            throw AppShortcutError.windowConflict(layout)
        case .windowManagement:
            throw AppShortcutError.windowManagementConflict
        case .screenshot:
            throw AppShortcutError.screenshotConflict
        case .clipboard:
            throw AppShortcutError.clipboardConflict
        case .appVolume:
            throw AppShortcutError.appVolumeConflict
        case .translation:
            throw AppShortcutError.translationConflict
        case let .app(path):
            throw AppShortcutError.conflict(path)
        case nil:
            break
        }

        bindings[app.path] = binding
        lastError = nil
        saveBindings()
    }

    func clearBinding(for app: LaunchableApp) {
        bindings.removeValue(forKey: app.path)
        lastError = nil
        saveBindings()
    }

    private func handle(keyCode: UInt16, modifiers: UInt) {
        guard let path = AppShortcutCatalog.match(
            keyCode: keyCode,
            modifiers: modifiers,
            bindings: bindings
        ), let app = launcher.application(atPath: path) else {
            return
        }

        guard launcher.launch(app) else {
            lastError = AppShortcutError.launchFailed(app.name).localizedDescription
            return
        }
        lastTriggeredPath = path
        lastError = nil
    }

    private func saveBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: "appShortcuts.bindings")
    }

    private static func loadBindings(from defaults: UserDefaults) -> [String: GlobalShortcut] {
        guard let data = defaults.data(forKey: "appShortcuts.bindings"),
              let values = try? JSONDecoder().decode([String: GlobalShortcut].self, from: data) else {
            return [:]
        }
        return values
    }
}
