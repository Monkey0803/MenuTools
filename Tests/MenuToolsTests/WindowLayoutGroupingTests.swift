import AppKit
import Testing
@testable import MenuTools

@Test("每个布局恰好属于一个分组")
func everyLayoutBelongsToExactlyOneGroup() {
    for layout in WindowLayout.allCases {
        let owners = WindowLayoutGroup.allCases.filter { $0.layouts.contains(layout) }
        #expect(owners.count == 1, "\(layout.rawValue) 属于 \(owners.count) 个分组")
        #expect(WindowLayoutGrouping.group(containing: layout) != nil)
    }
}

@Test("分组覆盖全部布局且没有重复")
func groupsCoverAllLayoutsWithoutDuplicates() {
    let grouped = WindowLayoutGroup.allCases.flatMap(\.layouts)
    #expect(grouped.count == WindowLayout.allCases.count)
    #expect(Set(grouped) == Set(WindowLayout.allCases))
}

@Test("每个分组都有可用的系统图标")
func groupSymbolsAreAvailable() {
    for group in WindowLayoutGroup.allCases {
        #expect(
            NSImage(systemSymbolName: group.symbol, accessibilityDescription: nil) != nil,
            "缺少图标：\(group.rawValue) -> \(group.symbol)"
        )
    }
}

@Test("搜索按本地化标题与英文标识过滤")
func searchMatchesLocalizedTitleAndIdentifier() {
    let titles: (WindowLayout) -> String = { layout in
        switch layout {
        case .leftHalf: return "左半屏"
        case .firstThird: return "第一列三分之一"
        default: return layout.rawValue
        }
    }

    #expect(WindowLayoutGrouping.matches(.leftHalf, query: "", title: titles))
    #expect(WindowLayoutGrouping.matches(.leftHalf, query: "左半", title: titles))
    // 中文界面下也能用英文标识搜
    #expect(WindowLayoutGrouping.matches(.leftHalf, query: "LEFT", title: titles))
    #expect(WindowLayoutGrouping.matches(.firstThird, query: "third", title: titles))
    #expect(!WindowLayoutGrouping.matches(.leftHalf, query: "六分之一", title: titles))
}

@Test("按分组过滤时跳过空分组")
func sectionsSkipEmptyGroups() {
    let titles: (WindowLayout) -> String = { layout in
        layout == .leftHalf ? "左半屏" : layout.rawValue
    }

    let all = WindowLayoutGrouping.sections(title: titles)
    #expect(all.count == WindowLayoutGroup.allCases.count)

    let filtered = WindowLayoutGrouping.sections(query: "左半屏", title: titles)
    #expect(filtered.count == 1)
    #expect(filtered.first?.group == .basic)
    #expect(filtered.first?.layouts == [.leftHalf])

    #expect(WindowLayoutGrouping.sections(query: "不存在的布局", title: titles).isEmpty)
}

@Test("默认只展开基础布局")
func defaultExpansionOnlyIncludesBasicGroup() {
    #expect(WindowLayoutGrouping.defaultExpandedGroups == [.basic])
}

@Test("搜索时一律展开，清空后回到手动状态")
func expansionFollowsSearchAndManualState() {
    // 无搜索：以手动集合为准
    #expect(!WindowLayoutGrouping.shouldExpand(.thirds, query: "", manuallyExpanded: [.basic]))
    #expect(WindowLayoutGrouping.shouldExpand(.basic, query: "", manuallyExpanded: [.basic]))
    #expect(WindowLayoutGrouping.shouldExpand(.thirds, query: "   ", manuallyExpanded: [.thirds]))

    // 搜索激活：即使是用户手动收起的分组也要展开（能被渲染说明它有命中）
    #expect(WindowLayoutGrouping.shouldExpand(.thirds, query: "第一列三分之一", manuallyExpanded: []))
    #expect(WindowLayoutGrouping.shouldExpand(.thirds, query: "third", manuallyExpanded: [.basic]))

    // 搜索清空后回到手动状态（搜索期间不写回手动集合）
    #expect(!WindowLayoutGrouping.shouldExpand(.thirds, query: "", manuallyExpanded: []))
}

@Test("搜索时渲染出来的分组都处于展开状态")
func everyFilteredSectionExpandsWhileSearching() {
    let titles: (WindowLayout) -> String = { $0 == .stashLeft ? "收纳到左边缘" : $0.rawValue }
    let sections = WindowLayoutGrouping.sections(query: "收纳", title: titles)

    #expect(!sections.isEmpty)
    for section in sections {
        #expect(WindowLayoutGrouping.shouldExpand(section.group, query: "收纳", manuallyExpanded: []))
    }
    // 没有命中的分组根本不会被渲染
    #expect(!sections.contains { $0.group == .quarters })
}
