import AppKit
import ApplicationServices
import Foundation
import Observation

enum ScreenshotShortcutCatalog {
    static func match(
        keyCode: UInt16,
        modifiers: UInt,
        bindings: [ScreenshotCaptureMode: GlobalShortcut]
    ) -> ScreenshotCaptureMode? {
        bindings.first {
            $0.value.keyCode == keyCode && $0.value.modifiers == modifiers
        }?.key
    }

    static func conflict(
        for shortcut: GlobalShortcut,
        excluding mode: ScreenshotCaptureMode,
        in bindings: [ScreenshotCaptureMode: GlobalShortcut]
    ) -> ScreenshotCaptureMode? {
        bindings.first { $0.key != mode && $0.value == shortcut }?.key
    }
}

/// 去重 global/local monitor 可能为同一个按键投递的重复 keyDown。
struct ScreenshotShortcutEventGate {
    private(set) var lastEvent: (keyCode: UInt16, modifiers: UInt, timestamp: TimeInterval)?

    mutating func accept(
        keyCode: UInt16,
        modifiers: UInt,
        timestamp: TimeInterval
    ) -> Bool {
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

enum ScreenshotShortcutError: LocalizedError, Equatable {
    case modifierRequired
    case systemConflict
    case otherApplicationConflict
    case sceneConflict(ScenePreset)
    case windowConflict(WindowLayout)
    case windowPresetConflict(String)
    case windowManagementConflict
    case appConflict(String)
    case screenshotConflict(ScreenshotCaptureMode)
    case clipboardConflict
    case appVolumeConflict
    case translationConflict

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
        case let .screenshotConflict(mode):
            return L("shortcut.error.conflict", L(mode.titleKey))
        case .clipboardConflict:
            return L("shortcut.error.conflict", L("settings.tab.clipboard"))
        case .appVolumeConflict:
            return L("shortcut.error.conflict", L("settings.tab.volume"))
        case .translationConflict:
            return L("shortcut.error.conflict", L("settings.tab.translation"))
        }
    }
}

/// 截图快捷键服务，独立于设置窗口持续监听。
@MainActor
@Observable
final class ScreenshotShortcutService {
    static let shared = ScreenshotShortcutService()

    private(set) var bindings: [ScreenshotCaptureMode: GlobalShortcut]
    private(set) var lastError: String?
    private(set) var isRunning = false
    private(set) var isAccessibilityTrusted = AXIsProcessTrusted()

    private let defaults: UserDefaults
    private let conflictChecker: any ShortcutConflictChecking
    private let screenshotService: ScreenshotService
    private let sceneBindingsProvider: @MainActor () -> [ScenePreset: GlobalShortcut]
    private let windowBindingsProvider: @MainActor () -> [WindowLayout: GlobalShortcut]
    private let appBindingsProvider: @MainActor () -> [String: GlobalShortcut]
    private let clipboardBindingProvider: @MainActor () -> GlobalShortcut?
    private let appVolumeBindingProvider: @MainActor () -> GlobalShortcut?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isRecordingShortcut = false
    private var eventGate = ScreenshotShortcutEventGate()

    init(
        defaults: UserDefaults = .standard,
        conflictChecker: any ShortcutConflictChecking = DefaultShortcutConflictChecker(),
        screenshotService: ScreenshotService = .shared,
        sceneBindingsProvider: @escaping @MainActor () -> [ScenePreset: GlobalShortcut] = { GlobalShortcutService.shared.bindings },
        windowBindingsProvider: @escaping @MainActor () -> [WindowLayout: GlobalShortcut] = { WindowShortcutService.shared.bindings },
        appBindingsProvider: @escaping @MainActor () -> [String: GlobalShortcut] = { AppShortcutService.shared.bindings },
        clipboardBindingProvider: @escaping @MainActor () -> GlobalShortcut? = { ClipboardShortcutService.shared.binding },
        appVolumeBindingProvider: @escaping @MainActor () -> GlobalShortcut? = { AppVolumeShortcutService.shared.binding }
    ) {
        self.defaults = defaults
        self.conflictChecker = conflictChecker
        self.screenshotService = screenshotService
        self.sceneBindingsProvider = sceneBindingsProvider
        self.windowBindingsProvider = windowBindingsProvider
        self.appBindingsProvider = appBindingsProvider
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
            let timestamp = event.timestamp
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, modifiers: modifiers, timestamp: timestamp)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = GlobalShortcutCatalog.normalizedModifiers(event.modifierFlags)
            let timestamp = event.timestamp
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, modifiers: modifiers, timestamp: timestamp)
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

    func setRecordingShortcut(_ recording: Bool) {
        isRecordingShortcut = recording
        if recording {
            eventGate.reset()
        }
    }

    func binding(for mode: ScreenshotCaptureMode) -> GlobalShortcut? {
        bindings[mode]
    }

    func setBinding(_ newBinding: GlobalShortcut, for mode: ScreenshotCaptureMode) throws {
        guard newBinding.modifiers & GlobalShortcutModifier.relevantMask != 0 else {
            throw ScreenshotShortcutError.modifierRequired
        }
        if let conflict = ScreenshotShortcutCatalog.conflict(
            for: newBinding,
            excluding: mode,
            in: bindings
        ) {
            throw ScreenshotShortcutError.screenshotConflict(conflict)
        }

        let context = ShortcutConflictContext(
            sceneBindings: sceneBindingsProvider(),
            windowBindings: windowBindingsProvider(),
            appBindings: appBindingsProvider(),
            screenshotBindings: bindings,
            clipboardBinding: clipboardBindingProvider(),
            appVolumeBinding: appVolumeBindingProvider(),
            excludingScene: nil,
            excludingWindow: nil,
            excludingAppPath: nil,
            excludingScreenshotMode: mode,
            excludingClipboard: false,
            excludingAppVolume: false
        )
        switch conflictChecker.conflict(for: newBinding, context: context) {
        case .system:
            throw ScreenshotShortcutError.systemConflict
        case .otherApplication:
            throw ScreenshotShortcutError.otherApplicationConflict
        case let .scene(scene):
            throw ScreenshotShortcutError.sceneConflict(scene)
        case let .window(layout):
            throw ScreenshotShortcutError.windowConflict(layout)
        case let .windowPreset(name):
            throw ScreenshotShortcutError.windowPresetConflict(name)
        case .windowManagement:
            throw ScreenshotShortcutError.windowManagementConflict
        case let .app(path):
            throw ScreenshotShortcutError.appConflict(path)
        case .clipboard:
            throw ScreenshotShortcutError.clipboardConflict
        case .appVolume:
            throw ScreenshotShortcutError.appVolumeConflict
        case .translation:
            throw ScreenshotShortcutError.translationConflict
        case .screenshot, nil:
            break
        }

        bindings[mode] = newBinding
        lastError = nil
        saveBinding()
    }

    func clearBinding(for mode: ScreenshotCaptureMode) {
        bindings.removeValue(forKey: mode)
        lastError = nil
        saveBinding()
    }

    private func handle(keyCode: UInt16, modifiers: UInt, timestamp: TimeInterval) {
        // 录入快捷键时，当前按键只能交给录入控件，不能启动截图。
        guard !isRecordingShortcut else { return }
        guard let mode = ScreenshotShortcutCatalog.match(
            keyCode: keyCode,
            modifiers: modifiers,
            bindings: bindings
        ) else { return }
        guard eventGate.accept(
            keyCode: keyCode,
            modifiers: modifiers,
            timestamp: timestamp
        ) else { return }

        // 长截图进入手动滚动阶段后，同一个快捷键用于确认结束，不能再启动
        // 第二个截图任务。
        if mode == .long && screenshotService.isCapturing {
            screenshotService.requestStopLongCapture()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await screenshotService.capture(
                    mode: mode,
                    copyToClipboard: screenshotService.copyToClipboard,
                    editAfterCapture: screenshotService.openEditorAfterCapture,
                    longSelectRegion: screenshotService.longSelectRegion
                )
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func saveBinding() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Self.bindingKey)
    }

    private static let bindingKey = "screenshot.shortcut"

    private static func loadBindings(from defaults: UserDefaults) -> [ScreenshotCaptureMode: GlobalShortcut] {
        guard let data = defaults.data(forKey: bindingKey) else { return [:] }
        if let bindings = try? JSONDecoder().decode([ScreenshotCaptureMode: GlobalShortcut].self, from: data) {
            return bindings
        }
        // 兼容早期只有一个截图快捷键的版本，将旧绑定迁移为全屏截图。
        if let legacyBinding = try? JSONDecoder().decode(GlobalShortcut.self, from: data) {
            return [.fullScreen: legacyBinding]
        }
        return [:]
    }
}
