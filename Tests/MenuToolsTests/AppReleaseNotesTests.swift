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

@Test("应用内更新说明优先读取所选语言，并在缺失时回退中文")
func releaseNotesLoadsLocalizedResource() throws {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsNotes-\(UUID().uuidString).bundle", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }
    let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    let english = resources.appendingPathComponent("en.lproj", isDirectory: true)
    try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
    try "## 1.1.6 — 2026-09-29\n- 中文说明\n".write(
        to: resources.appendingPathComponent("ReleaseNotes.md"), atomically: true, encoding: .utf8
    )
    try "## 1.1.6 — 2026-09-29\n- English notes\n".write(
        to: english.appendingPathComponent("ReleaseNotes.md"), atomically: true, encoding: .utf8
    )
    let bundle = try #require(Bundle(url: bundleURL))

    #expect(AppReleaseNotes.note(for: "1.1.6", language: "en", bundle: bundle)?.bullets == ["English notes"])
    #expect(AppReleaseNotes.note(for: "1.1.6", language: "ko", bundle: bundle)?.bullets == ["中文说明"])
}
