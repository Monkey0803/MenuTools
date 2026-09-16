import Foundation

/// 布局分组：60 种布局平铺成一整面墙太难找，按形状族归类。
///
/// 每个布局必须恰好属于一个分组，`WindowLayoutGroupingTests` 会守住这条约束——
/// 以后新增布局时忘了归类，测试会直接失败。
enum WindowLayoutGroup: String, CaseIterable, Identifiable, Sendable {
    case basic
    case thirds
    case quarters
    case sixths
    case display
    case nudge
    case stash

    var id: String { rawValue }
    var titleKey: String { "window.group.\(rawValue)" }
    var symbol: String {
        switch self {
        case .basic: return "rectangle.inset.filled"
        case .thirds: return "rectangle.split.3x1"
        case .quarters: return "rectangle.grid.2x2"
        case .sixths: return "rectangle.grid.3x2"
        case .display: return "display.2"
        case .nudge: return "arrow.up.and.down.and.arrow.left.and.right"
        case .stash: return "arrow.left.to.line"
        }
    }

    var layouts: [WindowLayout] {
        switch self {
        case .basic:
            return [
                .leftHalf, .rightHalf, .topHalf, .bottomHalf,
                .maximize, .toggleFullscreen, .almostMaximize,
                .maxWidth, .maxHeight, .reasonableSize, .centered,
                .makeLarger, .makeSmaller, .restore
            ]
        case .thirds:
            return [
                .firstThird, .centerThird, .lastThird,
                .firstTwoThirds, .centerTwoThirds, .lastTwoThirds,
                .topThird, .middleThird, .bottomThird,
                .topTwoThirds, .bottomTwoThirds,
                .topThreeFourths, .bottomThreeFourths
            ]
        case .quarters:
            return [
                .topLeft, .topRight, .bottomLeft, .bottomRight,
                .firstFourth, .secondFourth, .thirdFourth, .lastFourth,
                .topFirstFourth, .topSecondFourth, .topThirdFourth, .topLastFourth,
                .firstThreeFourths, .centerThreeFourths, .lastThreeFourths
            ]
        case .sixths:
            return [
                .topLeftSixth, .topCenterSixth, .topRightSixth,
                .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
                .topCenterTwoThirds, .bottomCenterTwoThirds
            ]
        case .display:
            return [.moveNextDisplay, .movePreviousDisplay, .moveNextDesktop, .movePreviousDesktop]
        case .nudge:
            return [.moveLeft, .moveRight, .moveUp, .moveDown]
        case .stash:
            return [.stashLeft, .stashRight]
        }
    }
}

enum WindowLayoutGrouping {
    /// 默认展开的分组：只展开最常用的基础布局，其余收起，避免一进页面就要滚很久。
    static let defaultExpandedGroups: Set<WindowLayoutGroup> = [.basic]

    /// 某个分组当前是否展开。
    ///
    /// 搜索激活时一律展开：能被渲染出来的分组本来就已经是「有命中」的（`sections(query:)`
    /// 会跳过空分组），此时再叠加折叠只会让人搜不到。
    /// 搜索清空后回到用户手动维护的折叠状态——搜索期间不写回手动集合。
    static func shouldExpand(
        _ group: WindowLayoutGroup,
        query: String,
        manuallyExpanded: Set<WindowLayoutGroup>
    ) -> Bool {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        return manuallyExpanded.contains(group)
    }

    /// 布局所属分组。
    static func group(containing layout: WindowLayout) -> WindowLayoutGroup? {
        WindowLayoutGroup.allCases.first { $0.layouts.contains(layout) }
    }

    /// 按分组列出布局；`query` 非空时只保留标题命中的布局。
    ///
    /// 标题由调用方提供，便于在 UI 里走本地化文案，同时让过滤逻辑保持可测。
    static func sections(
        query: String = "",
        title: (WindowLayout) -> String
    ) -> [(group: WindowLayoutGroup, layouts: [WindowLayout])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return WindowLayoutGroup.allCases.compactMap { group in
            let layouts = group.layouts.filter { matches($0, query: trimmed, title: title) }
            return layouts.isEmpty ? nil : (group, layouts)
        }
    }

    static func matches(_ layout: WindowLayout, query: String, title: (WindowLayout) -> String) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let haystack = title(layout).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        // 布局的英文标识也参与匹配：中文界面下用户仍可能想搜 left / third
        let identifier = layout.rawValue.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return haystack.contains(needle) || identifier.contains(needle)
    }
}
