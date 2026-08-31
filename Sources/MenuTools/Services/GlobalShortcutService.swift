import AppKit
import ApplicationServices
import Foundation
import Observation

enum GlobalShortcutModifier {
    static let controlOption = NSEvent.ModifierFlags([.control, .option]).rawValue
    static let relevantMask = NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue
}

struct GlobalShortcut: Codable, Equatable, Hashable, Sendable {
    let keyCode: UInt16
    let modifiers: UInt

    var displayName: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        if flags.contains(.command) { prefix += "⌘" }
        return prefix + Self.keyName(for: keyCode)
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key (keyCode)"
        }
    }
}

enum GlobalShortcutCatalog {
    static let defaults: [ScenePreset: GlobalShortcut] = [
        .work: GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption),
        .demo: GlobalShortcut(keyCode: 19, modifiers: GlobalShortcutModifier.controlOption),
        .night: GlobalShortcut(keyCode: 20, modifiers: GlobalShortcutModifier.controlOption)
    ]

    static func match(
        keyCode: UInt16,
        modifiers: UInt,
        bindings: [ScenePreset: GlobalShortcut]
    ) -> ScenePreset? {
        bindings.first { $0.value.keyCode == keyCode && $0.value.modifiers == modifiers }?.key
    }

    static func conflict(
        for binding: GlobalShortcut,
        excluding scene: ScenePreset,
        in bindings: [ScenePreset: GlobalShortcut]
    ) -> ScenePreset? {
        bindings.first { $0.key != scene && $0.value == binding }?.key
    }

    static func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> UInt {
        flags.intersection([.command, .option, .control, .shift]).rawValue
    }
}

enum GlobalShortcutError: LocalizedError, Equatable {
    case modifierRequired
    case conflict(ScenePreset)
    case systemConflict
    case otherApplicationConflict
    case windowConflict(WindowLayout)
    case appConflict(String)
    case screenshotConflict
    case clipboardConflict
    case appVolumeConflict

    var errorDescription: String? {
        switch self {
        case .modifierRequired: return L("shortcut.error.modifierRequired")
        case let .conflict(scene): return L("shortcut.error.conflict", L(scene.titleKey))
        case .systemConflict: return L("shortcut.error.systemConflict")
        case .otherApplicationConflict: return L("shortcut.error.otherApplicationConflict")
        case let .windowConflict(layout): return L("shortcut.error.conflict", L(layout.titleKey))
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
        }
    }
}

@MainActor
@Observable
final class GlobalShortcutService {
    static let shared = GlobalShortcutService()

    private(set) var bindings: [ScenePreset: GlobalShortcut]
    private(set) var lastTriggeredScene: ScenePreset?
    private(set) var lastError: String?
    private(set) var isRunning = false
    private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    private let defaults: UserDefaults
    private let conflictChecker: any ShortcutConflictChecking
    private let windowBindingsProvider: @MainActor () -> [WindowLayout: GlobalShortcut]
    private let appBindingsProvider: @MainActor () -> [String: GlobalShortcut]
    private let screenshotBindingsProvider: @MainActor () -> [ScreenshotCaptureMode: GlobalShortcut]
    private let clipboardBindingProvider: @MainActor () -> GlobalShortcut?
    private let appVolumeBindingProvider: @MainActor () -> GlobalShortcut?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(
        defaults: UserDefaults = .standard,
        conflictChecker: any ShortcutConflictChecking = DefaultShortcutConflictChecker(),
        windowBindingsProvider: @escaping @MainActor () -> [WindowLayout: GlobalShortcut] = { WindowShortcutService.shared.bindings },
        appBindingsProvider: @escaping @MainActor () -> [String: GlobalShortcut] = { AppShortcutService.shared.bindings },
        screenshotBindingsProvider: @escaping @MainActor () -> [ScreenshotCaptureMode: GlobalShortcut] = { ScreenshotShortcutService.shared.bindings },
        clipboardBindingProvider: @escaping @MainActor () -> GlobalShortcut? = { ClipboardShortcutService.shared.binding },
        appVolumeBindingProvider: @escaping @MainActor () -> GlobalShortcut? = { AppVolumeShortcutService.shared.binding }
    ) {
        self.defaults = defaults
        self.conflictChecker = conflictChecker
        self.windowBindingsProvider = windowBindingsProvider
        self.appBindingsProvider = appBindingsProvider
        self.screenshotBindingsProvider = screenshotBindingsProvider
        self.clipboardBindingProvider = clipboardBindingProvider
        self.appVolumeBindingProvider = appVolumeBindingProvider
        self.bindings = GlobalShortcutService.loadBindings(from: defaults)
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

    func binding(for scene: ScenePreset) -> GlobalShortcut? {
        bindings[scene]
    }

    func setBinding(_ binding: GlobalShortcut, for scene: ScenePreset) throws {
        guard binding.modifiers & GlobalShortcutModifier.relevantMask != 0 else {
            throw GlobalShortcutError.modifierRequired
        }
        if let conflict = GlobalShortcutCatalog.conflict(for: binding, excluding: scene, in: bindings) {
            throw GlobalShortcutError.conflict(conflict)
        }
        let context = ShortcutConflictContext(
            sceneBindings: bindings,
            windowBindings: windowBindingsProvider(),
            appBindings: appBindingsProvider(),
            screenshotBindings: screenshotBindingsProvider(),
            clipboardBinding: clipboardBindingProvider(),
            appVolumeBinding: appVolumeBindingProvider(),
            excludingScene: scene,
            excludingWindow: nil,
            excludingAppPath: nil,
            excludingScreenshotMode: nil,
            excludingClipboard: false,
            excludingAppVolume: false
        )
        switch conflictChecker.conflict(for: binding, context: context) {
        case .system:
            throw GlobalShortcutError.systemConflict
        case .otherApplication:
            throw GlobalShortcutError.otherApplicationConflict
        case let .window(layout):
            throw GlobalShortcutError.windowConflict(layout)
        case let .scene(conflict):
            throw GlobalShortcutError.conflict(conflict)
        case let .app(path):
            throw GlobalShortcutError.appConflict(path)
        case .screenshot:
            throw GlobalShortcutError.screenshotConflict
        case .clipboard:
            throw GlobalShortcutError.clipboardConflict
        case .appVolume:
            throw GlobalShortcutError.appVolumeConflict
        case nil:
            break
        }
        bindings[scene] = binding
        saveBindings()
    }

    func clearBinding(for scene: ScenePreset) {
        bindings.removeValue(forKey: scene)
        saveBindings()
    }

    private func handle(keyCode: UInt16, modifiers: UInt) {
        guard let scene = GlobalShortcutCatalog.match(keyCode: keyCode, modifiers: modifiers, bindings: bindings) else {
            return
        }
        do {
            try SceneService.shared.apply(
                scene,
                launcher: AppLauncherService.shared,
                focusService: FocusModeService.shared
            )
            lastTriggeredScene = scene
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func saveBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: "globalShortcuts.bindings")
    }

    private static func loadBindings(from defaults: UserDefaults) -> [ScenePreset: GlobalShortcut] {
        guard let data = defaults.data(forKey: "globalShortcuts.bindings"),
              let values = try? JSONDecoder().decode([ScenePreset: GlobalShortcut].self, from: data) else {
            return GlobalShortcutCatalog.defaults
        }
        return values
    }

}
