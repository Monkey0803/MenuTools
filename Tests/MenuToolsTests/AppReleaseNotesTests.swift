import Foundation
import Testing
@testable import MenuTools

private let sampleReleaseNotes = """
# 更新说明

## 1.1.1 — 2026-09-20

- 后台检查到新版本时改为温和提醒，不再静默升级
- 设置页显示发布日期与更新说明

## 1.1.0 — 2026-09-14

- 网络流量模块
- 剪贴板共享同步

## 1.0.4

首个稳定版本。
"""

@Test("能按版本解析出更新说明与发布日期")
func releaseNotesParsesVersionSection() throws {
    let note = try #require(AppReleaseNotes.note(for: "1.1.1", in: sampleReleaseNotes))

    #expect(note.version == "1.1.1")
    #expect(note.dateText == "2026-09-20")
    #expect(note.bullets.count == 2)
    #expect(note.bullets.first == "后台检查到新版本时改为温和提醒，不再静默升级")
}

@Test("解析中间版本不会读到相邻版本的内容")
func releaseNotesStopsAtNextSection() throws {
    let note = try #require(AppReleaseNotes.note(for: "1.1.0", in: sampleReleaseNotes))

    #expect(note.dateText == "2026-09-14")
    #expect(note.bullets == ["网络流量模块", "剪贴板共享同步"])
    #expect(!note.bullets.contains { $0.contains("温和提醒") })
}

@Test("没有日期或没有条目的版本也能解析")
func releaseNotesHandlesMissingDateAndBullets() throws {
    let note = try #require(AppReleaseNotes.note(for: "1.0.4", in: sampleReleaseNotes))

    #expect(note.dateText == nil)
    #expect(note.bullets == ["首个稳定版本。"])
}

@Test("版本不存在时返回 nil")
func releaseNotesReturnsNilForUnknownVersion() {
    #expect(AppReleaseNotes.note(for: "9.9.9", in: sampleReleaseNotes) == nil)
}

@Test("空文件或没有标题时不会崩溃")
func releaseNotesHandlesEmptyInput() {
    #expect(AppReleaseNotes.note(for: "1.1.1", in: "") == nil)
    #expect(AppReleaseNotes.note(for: "1.1.1", in: "# 更新说明\n\n还没有内容\n") == nil)
}
