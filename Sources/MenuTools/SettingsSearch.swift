import Foundation

/// 设置页的全局搜索（纯逻辑，便于回归）。
///
/// 15 个 tab 此前只能靠鼠标在侧边栏里翻，也没有任何搜索入口：
/// 想找「在哪关掉截图历史」只能逐个页面点过去。
enum SettingsSearch {
    struct Entry: Equatable {
        var tab: SettingsTab
        /// 已本地化的页面标题（走既有五语种键，不新增文案）。
        var title: String
        /// 别名：kebab 化的 rawValue，让英文/拼音式输入（`runtime-status`、`app-launch`）也能命中。
        var aliases: [String]
    }

    /// 大小写不敏感的子串匹配。
    ///
    /// 空查询返回空数组而不是全部结果：搜索框空着时不该展示一份没有信息量的「全部页面」列表。
    static func matching(_ entries: [Entry], query: String) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return entries.filter { entry in
            entry.title.lowercased().contains(needle)
                || entry.aliases.contains { $0.lowercased().contains(needle) }
        }
    }
}

/// 搜索索引：每个 page 一条。
enum SettingsSearchIndex {
    @MainActor
    static func entries() -> [SettingsSearch.Entry] {
        SettingsTab.allCases.map { tab in
            SettingsSearch.Entry(
                tab: tab,
                title: L(tab.titleKey),
                aliases: [WindowLayoutURLName.kebab(tab.rawValue)]
            )
        }
    }
}
