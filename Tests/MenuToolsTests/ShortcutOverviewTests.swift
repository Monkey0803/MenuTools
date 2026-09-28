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
