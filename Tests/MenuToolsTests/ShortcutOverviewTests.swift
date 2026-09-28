import AppKit
import Testing
@testable import MenuTools

@Test("快捷键总览标出重复绑定，唯一的条目冲突数为零")
func shortcutOverviewMarksConflicts() {
    let duplicate = GlobalShortcut(
        keyCode: 13,
        modifiers: NSEvent.ModifierFlags.command.rawValue
    )
    let entries = ShortcutOverview.entries(from: [
        .init(moduleKey: "plugin.window-management.title", action: "左半屏", shortcut: duplicate),
        .init(moduleKey: "plugin.automation.title", action: "夜间", shortcut: duplicate),
        .init(moduleKey: "plugin.screenshot.title", action: "全屏", shortcut: GlobalShortcut(keyCode: 1, modifiers: 0))
    ])

    #expect(entries.count == 3)
    #expect(entries[0].conflictCount == 1)
    #expect(entries[1].conflictCount == 1)
    #expect(entries[2].conflictCount == 0)
    #expect(entries[0].id != entries[1].id)

    // 没有任何绑定时为空，不产生占位行
    #expect(ShortcutOverview.entries(from: []).isEmpty)
}

@Test("快捷键总览可以从当前各模块设置聚合")
@MainActor
func shortcutOverviewBuildsFromLiveServices() {
    let entries = ShortcutOverviewBuilder.liveEntries()
    #expect(entries.allSatisfy { $0.conflictCount >= 0 && !$0.moduleKey.isEmpty && !$0.action.isEmpty })
}

@Test("快捷键总览的跳转目标按模块映射，没有设置页的模块不产出跳转")
func shortcutOverviewMapsModulesToSettingsTabs() {
    #expect(ShortcutOverview.moduleSettingsTab(moduleKey: "plugin.window-management.title") == .windowManagement)
    #expect(ShortcutOverview.moduleSettingsTab(moduleKey: "plugin.app-launcher.title") == .appLaunch)
    #expect(ShortcutOverview.moduleSettingsTab(moduleKey: "plugin.screenshot.title") == .screenshot)
    #expect(ShortcutOverview.moduleSettingsTab(moduleKey: "plugin.clipboard.title") == .clipboard)
    #expect(ShortcutOverview.moduleSettingsTab(moduleKey: "plugin.app-volume.title") == .volume)
    // 场景/快捷键目前只在面板卡片里配置，没有独立设置页，不应产出无效跳转
    #expect(ShortcutOverview.moduleSettingsTab(moduleKey: "plugin.automation.title") == nil)
}
