import AppKit
import ApplicationServices
import Foundation
import Observation

enum WindowShortcutError: LocalizedError, Equatable {
    case modifierRequired
    case conflict(WindowLayout)

    var errorDescription: String? {
        switch self {
        case .modifierRequired:
            return L("shortcut.error.modifierRequired")
        case let .conflict(layout):
            return L("shortcut.error.conflict", L(layout.titleKey))
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
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
