import Foundation
import Testing
@testable import MenuTools

private func historyEntry(
    name: String,
    createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
    mode: ScreenshotCaptureMode = .fullScreen
) -> ScreenshotHistoryEntry {
    ScreenshotHistoryEntry(
        fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
        createdAt: createdAt,
        width: 100,
        height: 50,
        format: .png,
        mode: mode
    )
}

@Test("截图历史按文件名筛选，大小写不敏感")
func screenshotHistoryFilterMatchesFileName() {
    let entries = [
        historyEntry(name: "Report-2026.png"),
        historyEntry(name: "screenshot-1.png"),
        historyEntry(name: "report-old.jpg")
    ]

    #expect(ScreenshotHistoryFilter.matching(entries, query: "").count == 3)
    #expect(ScreenshotHistoryFilter.matching(entries, query: "   ").count == 3)
    #expect(ScreenshotHistoryFilter.matching(entries, query: "report").count == 2)
    #expect(ScreenshotHistoryFilter.matching(entries, query: "REPORT").count == 2)
    #expect(ScreenshotHistoryFilter.matching(entries, query: "screenshot-1").count == 1)
    #expect(ScreenshotHistoryFilter.matching(entries, query: "none").isEmpty)
}

@Test("截图历史折叠：默认露 8 条，展开显示全部，并给出隐藏条数")
func screenshotHistoryFilterCollapses() {
    let entries = (0 ..< 50).map { historyEntry(name: "shot-\($0).png") }

    #expect(ScreenshotHistoryFilter.visible(entries, isExpanded: false).count == 8)
    #expect(ScreenshotHistoryFilter.visible(entries, isExpanded: true).count == 50)
    #expect(ScreenshotHistoryFilter.hiddenCount(entries, isExpanded: false) == 42)
    #expect(ScreenshotHistoryFilter.hiddenCount(entries, isExpanded: true) == 0)

    // 不足折叠条数时不产生「展开」入口
    let few = (0 ..< 3).map { historyEntry(name: "few-\($0).png") }
    #expect(ScreenshotHistoryFilter.visible(few, isExpanded: false).count == 3)
    #expect(ScreenshotHistoryFilter.hiddenCount(few, isExpanded: false) == 0)

    // 折叠条数可配置，且非法值不会返回空列表
    #expect(ScreenshotHistoryFilter.visible(entries, isExpanded: false, collapsedLimit: 12).count == 12)
    #expect(ScreenshotHistoryFilter.visible(entries, isExpanded: false, collapsedLimit: 0).count == 1)
}
