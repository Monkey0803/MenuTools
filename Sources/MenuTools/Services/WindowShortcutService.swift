import AppKit
import ApplicationServices
import Foundation
import Observation

enum WindowShortcutError: LocalizedError, Equatable {
    case modifierRequired
    case conflict(WindowLayout)
    case systemConflict
    case otherApplicationConflict
    case sceneConflict(ScenePreset)

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
}

/// 窗口布局快捷键的持久化与全局监听服务。
@MainActor
@Observable
final class WindowShortcutService {
    static let shared = WindowShortcutService()

    private(set) var bindings: [WindowLayout: GlobalShortcut]
    private(set) var lastError: String?
    private(set) var isRunning = false
    private(set) var isAccessibilityTrusted = AXIsProcessTrusted()

    private let defaults: UserDefaults
    private let conflictChecker: any ShortcutConflictChecking
    private let sceneBindingsProvider: @MainActor () -> [ScenePreset: GlobalShortcut]
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(
        defaults: UserDefaults = .standard,
        conflictChecker: any ShortcutConflictChecking = DefaultShortcutConflictChecker(),
        sceneBindingsProvider: @escaping @MainActor () -> [ScenePreset: GlobalShortcut] = { GlobalShortcutService.shared.bindings }
    ) {
        self.defaults = defaults
        self.bindings = Self.loadBindings(from: defaults)
        self.conflictChecker = conflictChecker
        self.sceneBindingsProvider = sceneBindingsProvider
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
        let context = ShortcutConflictContext(
            sceneBindings: sceneBindingsProvider(),
            windowBindings: bindings,
            excludingScene: nil,
            excludingWindow: layout
        )
        switch conflictChecker.conflict(for: binding, context: context) {
        case .system:
            throw WindowShortcutError.systemConflict
        case .otherApplication:
            throw WindowShortcutError.otherApplicationConflict
        case let .scene(scene):
            throw WindowShortcutError.sceneConflict(scene)
        case let .window(conflict):
            throw WindowShortcutError.conflict(conflict)
        case nil:
            break
        }
        bindings[layout] = binding
        lastError = nil
        saveBindings()
    }

    func clearBinding(for layout: WindowLayout) {
        bindings.removeValue(forKey: layout)
        lastError = nil
        saveBindings()
    }

    private func handle(keyCode: UInt16, modifiers: UInt) {
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

    private func saveBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Self.bindingsKey)
    }

    private static let bindingsKey = "windowManagement.shortcuts"

    private static func loadBindings(from defaults: UserDefaults) -> [WindowLayout: GlobalShortcut] {
        guard let data = defaults.data(forKey: bindingsKey),
              let values = try? JSONDecoder().decode([WindowLayout: GlobalShortcut].self, from: data) else {
            return [:]
        }
        return values
    }
}
