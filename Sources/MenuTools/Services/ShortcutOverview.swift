import AppKit
import Foundation

/// 快捷键总览里的一行。
struct ShortcutOverviewEntry: Equatable, Identifiable {
    var moduleKey: String
    var action: String
    var shortcut: GlobalShortcut
    /// 与同键其他条目的数量（0 表示唯一）。
    var conflictCount: Int

    var id: String { "\(moduleKey)|\(action)|\(shortcut.displayName)" }
}

/// 全局快捷键的只读汇总与冲突统计。
///
/// 快捷键入口分散在窗口管理、自动化、启动器、截图、剪贴板、音量等多个设置页里，
/// 用户没有任何一处能看到「一共配了哪些」以及「有没有按键被占用两次」。
enum ShortcutOverview {
    struct Binding: Equatable {
        var moduleKey: String
        var action: String
        var shortcut: GlobalShortcut
    }

    private struct Key: Hashable {
        var keyCode: UInt16
        var modifiers: UInt
    }

    /// 条目所属模块的设置页；没有独立设置页的模块返回 nil（不要产出点了没反应的跳转）。
    static func moduleSettingsTab(moduleKey: String) -> SettingsTab? {
        switch moduleKey {
        case "plugin.window-management.title": return .windowManagement
        case "plugin.app-launcher.title": return .appLaunch
        case "plugin.screenshot.title": return .screenshot
        case "plugin.clipboard.title": return .clipboard
        case "plugin.app-volume.title": return .volume
        default: return nil
        }
    }

    /// 按 (keyCode, modifiers) 统计重复，并把冲突数写到每个条目上。
    static func entries(from bindings: [Binding]) -> [ShortcutOverviewEntry] {
        let counts = Dictionary(
            grouping: bindings,
            by: { Key(keyCode: $0.shortcut.keyCode, modifiers: $0.shortcut.modifiers) }
        ).mapValues(\.count)

        return bindings.map { binding in
            let key = Key(keyCode: binding.shortcut.keyCode, modifiers: binding.shortcut.modifiers)
            return ShortcutOverviewEntry(
                moduleKey: binding.moduleKey,
                action: binding.action,
                shortcut: binding.shortcut,
                conflictCount: max((counts[key] ?? 1) - 1, 0)
            )
        }
    }
}

/// 从各模块服务读取当前生效的快捷键。
@MainActor
enum ShortcutOverviewBuilder {
    static func liveEntries() -> [ShortcutOverviewEntry] {
        ShortcutOverview.entries(from: liveBindings())
    }

    static func liveBindings() -> [ShortcutOverview.Binding] {
        var bindings: [ShortcutOverview.Binding] = []

        let windowManagementKey = "plugin.window-management.title"
        let windowShortcuts = WindowShortcutService.shared
        for (layout, shortcut) in windowShortcuts.bindings {
            bindings.append(.init(moduleKey: windowManagementKey, action: L(layout.titleKey), shortcut: shortcut))
        }
        for preset in windowShortcuts.presetShortcuts {
            bindings.append(.init(moduleKey: windowManagementKey, action: preset.name, shortcut: preset.shortcut))
        }
        if let quickAccess = windowShortcuts.quickAccessBinding {
            bindings.append(.init(
                moduleKey: windowManagementKey,
                action: L("window.quickAccess.shortcut"),
                shortcut: quickAccess
            ))
        }

        for (scene, shortcut) in GlobalShortcutService.shared.bindings {
            bindings.append(.init(moduleKey: "plugin.automation.title", action: L(scene.titleKey), shortcut: shortcut))
        }

        let launcher = AppLauncherService.shared
        for (path, shortcut) in AppShortcutService.shared.bindings {
            let name = launcher.application(atPath: path)?.name
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            bindings.append(.init(moduleKey: "plugin.app-launcher.title", action: name, shortcut: shortcut))
        }

        for (mode, shortcut) in ScreenshotShortcutService.shared.bindings {
            bindings.append(.init(moduleKey: "plugin.screenshot.title", action: L(mode.titleKey), shortcut: shortcut))
        }
        if let shortcut = ClipboardShortcutService.shared.binding {
            bindings.append(.init(moduleKey: "plugin.clipboard.title", action: L("clipboard.shortcut"), shortcut: shortcut))
        }
        if let shortcut = AppVolumeShortcutService.shared.binding {
            bindings.append(.init(moduleKey: "plugin.app-volume.title", action: L("volume.shortcut"), shortcut: shortcut))
        }

        return bindings
    }
}
