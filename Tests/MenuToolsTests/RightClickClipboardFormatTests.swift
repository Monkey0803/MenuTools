import AppKit
import Foundation
import Testing
@testable import MenuTools

@Test("剪贴板快照按格式提供导出数据")
func rightClickClipboardPayloadExposesFormats() {
    let payload = RightClickClipboardPayload(
        text: "hello", png: Data([1, 2, 3]), rtf: Data([4, 5]), html: "<p>hello</p>")

    #expect(payload.availableFormats == [.png, .txt, .md, .rtf, .html])
    #expect(payload.data(for: .txt) == Data("hello".utf8))
    #expect(payload.data(for: .md) == Data("hello".utf8))
    #expect(payload.data(for: .rtf) == Data([4, 5]))
    #expect(payload.data(for: .html) == Data("<p>hello</p>".utf8))
    #expect(payload.data(for: .png) == Data([1, 2, 3]))

    #expect(RightClickClipboardPayload().isEmpty)
    #expect(RightClickClipboardPayload().availableFormats.isEmpty)
    #expect(RightClickClipboardPayload().data(for: .txt) == nil)
    #expect(RightClickClipboardPayload().data(for: .rtf) == nil)
    #expect(RightClickClipboardPayload().data(for: .png) == nil)
}

@Test("富文本剪贴板同时提供 RTF 与纯文本")
@MainActor func rightClickClipboardPayloadReadsRichText() throws {
    let board = NSPasteboard(name: .init("MenuTools.RightClickRichText.\(UUID())"))
    defer { board.releaseGlobally() }
    board.clearContents()
    let attributed = NSAttributedString(string: "富文本 🎉")
    let rtf = try attributed.data(
        from: NSRange(location: 0, length: attributed.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    #expect(board.setData(rtf, forType: .rtf))

    let payload = try #require(RightClickClipboardReader.payload(from: board))
    #expect(payload.rtf == rtf)
    #expect(payload.availableFormats.contains(.rtf))
    // 模板变量仍取纯文本，不被富文本表示顶掉。
    #expect(RightClickClipboardReader.read(from: board) == .text("富文本 🎉"))
}

@Test("HTML 剪贴板提供 HTML 导出")
@MainActor func rightClickClipboardPayloadReadsHTML() throws {
    let board = NSPasteboard(name: .init("MenuTools.RightClickHTML.\(UUID())"))
    defer { board.releaseGlobally() }
    board.clearContents()
    #expect(board.setString("<p>hello</p>", forType: .html))

    let payload = try #require(RightClickClipboardReader.payload(from: board))
    #expect(payload.availableFormats.contains(.html))
    #expect(payload.data(for: .html) == Data("<p>hello</p>".utf8))
}

@Test("文件引用和空剪贴板不提供任何格式")
@MainActor func rightClickClipboardPayloadRejectsFileReferences() {
    let board = NSPasteboard(name: .init("MenuTools.RightClickFileRef.\(UUID())"))
    defer { board.releaseGlobally() }
    board.clearContents()
    #expect(board.setString("file:///tmp/file.txt", forType: .fileURL))
    #expect(RightClickClipboardReader.payload(from: board) == nil)
    #expect(RightClickClipboardReader.read(from: board) == nil)

    board.clearContents()
    #expect(RightClickClipboardReader.payload(from: board) == nil)
}

@Test("图片剪贴板只提供 PNG 导出")
@MainActor func rightClickClipboardPayloadImageOnlyOffersPNG() throws {
    let board = NSPasteboard(name: .init("MenuTools.RightClickImageOnly.\(UUID())"))
    defer { board.releaseGlobally() }
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 4, bitsPerPixel: 32))
    bitmap.setColor(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1), atX: 0, y: 0)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    board.clearContents()
    #expect(board.setData(png, forType: .png))

    let payload = try #require(RightClickClipboardReader.payload(from: board))
    #expect(payload.availableFormats == [.png])
    #expect(payload.data(for: .png)?.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
}
