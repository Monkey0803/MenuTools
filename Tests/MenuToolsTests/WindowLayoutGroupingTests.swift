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
