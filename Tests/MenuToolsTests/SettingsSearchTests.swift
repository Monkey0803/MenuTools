import Testing
@testable import MenuTools

@Test("设置搜索：大小写不敏感的标题与别名匹配，空查询不产出结果")
func settingsSearchMatchesTitleAndAlias() {
    let entries = [
        SettingsSearch.Entry(tab: .clipboard, title: "剪贴板", aliases: ["clipboard"]),
        SettingsSearch.Entry(tab: .runtimeStatus, title: "权限与运行状态", aliases: ["runtime-status"]),
        SettingsSearch.Entry(tab: .systemResources, title: "系统监控", aliases: ["system-resources"])
    ]

    // 中文标题子串
    #expect(SettingsSearch.matching(entries, query: "剪贴").map(\.tab) == [.clipboard])
    #expect(SettingsSearch.matching(entries, query: "状态").map(\.tab) == [.runtimeStatus])
    #expect(SettingsSearch.matching(entries, query: "监控").map(\.tab) == [.systemResources])

    // 别名与大小写
    #expect(SettingsSearch.matching(entries, query: "CLIPBOARD").map(\.tab) == [.clipboard])
    #expect(SettingsSearch.matching(entries, query: "runtime").map(\.tab) == [.runtimeStatus])
    #expect(SettingsSearch.matching(entries, query: "system-res").map(\.tab) == [.systemResources])

    // 空查询 / 纯空白：不展示「全部」噪音
    #expect(SettingsSearch.matching(entries, query: "").isEmpty)
    #expect(SettingsSearch.matching(entries, query: "   ").isEmpty)
    // 没有命中就是空
    #expect(SettingsSearch.matching(entries, query: "不存在的页面").isEmpty)
}

@Test("搜索索引覆盖全部页面，别名是 kebab 化的 rawValue")
@MainActor
func settingsSearchIndexCoversEveryTab() {
    let entries = SettingsSearchIndex.entries()
    #expect(entries.count == SettingsTab.allCases.count)
    #expect(Set(entries.map(\.tab)).count == SettingsTab.allCases.count)
    #expect(entries.allSatisfy { !$0.title.isEmpty })
    #expect(entries.allSatisfy { $0.aliases == [WindowLayoutURLName.kebab($0.tab.rawValue)] })

    // 用 kebab 别名能搜到自己（英文输入可用）
    for entry in entries {
        #expect(SettingsSearch.matching(entries, query: entry.aliases[0]).contains(entry))
    }
}
