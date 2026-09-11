import AppKit
import SQLite3
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import MenuTools

@Test("剪贴板历史可以按内容类型应用独立保留期限")
func clipboardHistorySupportsPerContentRetention() {
    let now = Date(timeIntervalSince1970: 10_000)
    let oldText = ClipboardHistoryItem(
        id: UUID(), content: .text("旧文本"), capturedAt: now.addingTimeInterval(-3 * 86_400), expiresAt: nil, isPinned: false
    )
    let oldImage = ClipboardHistoryItem(
        id: UUID(), content: .image(Data([1, 2, 3])), capturedAt: now.addingTimeInterval(-3 * 86_400), expiresAt: nil, isPinned: false
    )
    let pinnedImage = ClipboardHistoryItem(
        id: UUID(), content: .image(Data([4, 5, 6])), capturedAt: now.addingTimeInterval(-3 * 86_400), expiresAt: nil, isPinned: true
    )
    var history = ClipboardHistoryBuffer(
        retentionDuration: 30 * 86_400,
        retentionByContentType: [.text: 1.0 * 86_400, .image: 2.0 * 86_400],
        items: [oldText, oldImage, pinnedImage]
    )

    history.applyAutomaticCleanup(now: now)

    #expect(history.items == [pinnedImage])
}

@Test("服务调整内容类型保留期限后会立即清理历史")
@MainActor
func clipboardServiceAppliesPerContentRetentionImmediately() throws {
    let suiteName = "MenuTools-ClipboardRetention-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    let oldItem = ClipboardHistoryItem(
        id: UUID(), content: .text("旧文本"),
        capturedAt: Date().addingTimeInterval(-2 * 86_400), expiresAt: nil, isPinned: false
    )
    let service = ClipboardHistoryService(persistenceURL: nil, userDefaults: defaults)
    service.importItems([oldItem])

    service.setRetentionDays(1, for: .text)

    #expect(service.items.isEmpty)
}

@Test("剪贴板历史支持批量置顶和敏感标记")
@MainActor
func clipboardHistorySupportsBatchMetadataActions() {
    let first = ClipboardHistoryItem(
        id: UUID(), content: .text("第一条"), capturedAt: Date(timeIntervalSince1970: 1_000), expiresAt: nil, isPinned: false
    )
    let second = ClipboardHistoryItem(
        id: UUID(), content: .text("第二条"), capturedAt: Date(timeIntervalSince1970: 2_000), expiresAt: nil, isPinned: false
    )
    let service = ClipboardHistoryService(persistenceURL: nil)
    service.importItems([first, second])
    let ids = Set([first.id, second.id])

    service.setPinned(true, for: ids)
    service.setSensitive(true, for: ids)

    #expect(service.items.allSatisfy { $0.isPinned && $0.isSensitive })
}

@Test("宽屏剪贴板设置页优先使用双列历史卡片")
func clipboardSettingsUsesAdaptiveHistoryGrid() {
    #expect(ClipboardHistorySettingsLayout.columnCount(for: 552) == 2)
    #expect(ClipboardHistorySettingsLayout.columnCount(for: 390) == 1)
}

@Test("剪贴板设置页拆分为三个低密度工作区")
func clipboardSettingsUsesFocusedWorkspaces() {
    #expect(ClipboardHistorySettingsTab.allCases.map(\.id) == ["history", "snippets", "settings"])
    #expect(ClipboardHistorySettingsTab.allCases.map(\.titleKey) == [
        "clipboard.history",
        "clipboard.snippets",
        "clipboard.tab.settings"
    ])
}

@Test("剪贴板辅助功能设置链接指向隐私与安全性页面")
func clipboardAccessibilitySettingsURLIsStable() {
    #expect(ClipboardAccessibilityPermission.settingsURL.absoluteString.contains("Privacy_Accessibility"))
}

@Test("文件历史会区分仍存在和已失效的路径")
func clipboardFileHistoryReportsAvailability() throws {
    let existingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-Clipboard-Existing-\(UUID().uuidString)")
    try Data().write(to: existingURL)
    defer { try? FileManager.default.removeItem(at: existingURL) }

    #expect(ClipboardHistoryFile(path: existingURL.path).isAvailable)
    #expect(!ClipboardHistoryFile(path: existingURL.appendingPathExtension("missing").path).isAvailable)
}

@Test("剪贴板快捷面板提供可伸缩的阅读尺寸")
func clipboardPopoverUsesFlexibleDimensions() {
    #expect(ClipboardHistoryPopoverLayout.minWidth < ClipboardHistoryPopoverLayout.idealWidth)
    #expect(ClipboardHistoryPopoverLayout.idealWidth < ClipboardHistoryPopoverLayout.maxWidth)
    #expect(ClipboardHistoryPopoverLayout.minHeight < ClipboardHistoryPopoverLayout.idealHeight)
    #expect(ClipboardHistoryPopoverLayout.idealHeight < ClipboardHistoryPopoverLayout.maxHeight)
}

@Test("剪贴板卡片缩略图和悬停预览使用固定尺寸")
func clipboardPreviewUsesConsistentFrames() {
    #expect(ClipboardHistoryPreviewLayout.thumbnailSize == CGSize(width: 64, height: 64))
    #expect(ClipboardHistoryPreviewLayout.hoverPreviewSize == CGSize(width: 272, height: 188))
}

@Test("剪贴板预览会根据卡片位置切换左右并跟随纵向位置")
func clipboardHoverPreviewFollowsHoveredCard() {
    let containerSize = CGSize(width: 552, height: 420)
    let leftCard = CGRect(x: 12, y: 80, width: 246, height: 88)
    let lowerLeftCard = CGRect(x: 12, y: 180, width: 246, height: 88)
    let rightCard = CGRect(x: 294, y: 80, width: 246, height: 88)

    let leftPosition = ClipboardHistoryPreviewPlacement.position(
        for: leftCard,
        in: containerSize
    )
    let lowerLeftPosition = ClipboardHistoryPreviewPlacement.position(
        for: lowerLeftCard,
        in: containerSize
    )
    let rightPosition = ClipboardHistoryPreviewPlacement.position(
        for: rightCard,
        in: containerSize
    )

    #expect(leftPosition.x > containerSize.width / 2)
    #expect(rightPosition.x < containerSize.width / 2)
    #expect(lowerLeftPosition.y > leftPosition.y)
}

@Test("剪贴板容量只提供四个可管理档位")
func clipboardHistoryCapacityOptionsAreSupported() {
    #expect(ClipboardHistoryLimit.allCases.map(\.rawValue) == [20, 50, 100, 200])
}

@Test("调整剪贴板容量会立即裁剪最旧的普通历史")
func clipboardHistoryTrimsWhenCapacityChanges() {
    var history = ClipboardHistoryBuffer(limit: 200)
    let now = Date(timeIntervalSince1970: 100)

    for index in 0 ..< 25 {
        history.insert(.text("记录 \(index)"), now: now.addingTimeInterval(Double(index)))
    }
    history.setLimit(20)

    #expect(history.items.count == 20)
    #expect(history.items.first?.content == .text("记录 24"))
    #expect(history.items.last?.content == .text("记录 5"))
}

@Test("剪贴板历史支持按分类、关键词和时间排序")
func clipboardHistoryFiltersAndSortsItems() {
    let oldestText = ClipboardHistoryItem(
        id: UUID(),
        content: .text("Apple 文本"),
        capturedAt: Date(timeIntervalSince1970: 100),
        expiresAt: nil,
        isPinned: false
    )
    let image = ClipboardHistoryItem(
        id: UUID(),
        content: .image(Data([1, 2, 3])),
        capturedAt: Date(timeIntervalSince1970: 200),
        expiresAt: nil,
        isPinned: false
    )
    let newestText = ClipboardHistoryItem(
        id: UUID(),
        content: .text("Apple 最新文本"),
        capturedAt: Date(timeIntervalSince1970: 300),
        expiresAt: nil,
        isPinned: false
    )

    let result = ClipboardHistoryList.items(
        from: [newestText, image, oldestText],
        query: "apple",
        category: .text,
        sortOrder: .oldestFirst
    )

    #expect(result == [oldestText, newestText])
    #expect(
        ClipboardHistoryList.items(
            from: [newestText, image, oldestText],
            query: "",
            category: .image,
            sortOrder: .newestFirst
        ) == [image]
    )
}

@Test("置顶项目在所有时间排序下都优先显示")
func clipboardHistoryPinnedItemsAlwaysAppearFirst() {
    let pinnedOldest = ClipboardHistoryItem(
        id: UUID(),
        content: .text("置顶旧记录"),
        capturedAt: Date(timeIntervalSince1970: 100),
        expiresAt: nil,
        isPinned: true
    )
    let pinnedNewest = ClipboardHistoryItem(
        id: UUID(),
        content: .text("置顶新记录"),
        capturedAt: Date(timeIntervalSince1970: 300),
        expiresAt: nil,
        isPinned: true
    )
    let newest = ClipboardHistoryItem(
        id: UUID(),
        content: .text("普通新记录"),
        capturedAt: Date(timeIntervalSince1970: 400),
        expiresAt: nil,
        isPinned: false
    )

    let newestFirst = ClipboardHistoryList.items(
        from: [newest, pinnedOldest, pinnedNewest],
        query: "",
        category: .all,
        sortOrder: .newestFirst
    )
    let oldestFirst = ClipboardHistoryList.items(
        from: [newest, pinnedOldest, pinnedNewest],
        query: "",
        category: .all,
        sortOrder: .oldestFirst
    )

    #expect(newestFirst == [pinnedNewest, pinnedOldest, newest])
    #expect(oldestFirst == [pinnedOldest, pinnedNewest, newest])
}

@Test("剪贴板面板可用上下方向键移动选择")
func clipboardHistoryKeyboardNavigationMovesSelection() {
    let first = ClipboardHistoryItem(
        id: UUID(),
        content: .text("第一条"),
        capturedAt: Date(timeIntervalSince1970: 300),
        expiresAt: nil,
        isPinned: false
    )
    let second = ClipboardHistoryItem(
        id: UUID(),
        content: .text("第二条"),
        capturedAt: Date(timeIntervalSince1970: 200),
        expiresAt: nil,
        isPinned: false
    )
    let third = ClipboardHistoryItem(
        id: UUID(),
        content: .text("第三条"),
        capturedAt: Date(timeIntervalSince1970: 100),
        expiresAt: nil,
        isPinned: false
    )
    let items = [first, second, third]

    #expect(
        ClipboardHistoryKeyboardNavigation.selection(
            in: items,
            from: nil,
            moving: .down
        ) == first.id
    )
    #expect(
        ClipboardHistoryKeyboardNavigation.selection(
            in: items,
            from: first.id,
            moving: .down
        ) == second.id
    )
    #expect(
        ClipboardHistoryKeyboardNavigation.selection(
            in: items,
            from: third.id,
            moving: .down
        ) == third.id
    )
    #expect(
        ClipboardHistoryKeyboardNavigation.selection(
            in: items,
            from: first.id,
            moving: .up
        ) == first.id
    )
    #expect(
        ClipboardHistoryKeyboardNavigation.selection(
            in: items,
            from: nil,
            moving: .up
        ) == third.id
    )
}

@Test("剪贴板面板按回车会复制选中项，未选择时复制首项")
func clipboardHistoryKeyboardActivationUsesSelectedOrFirstItem() {
    let first = ClipboardHistoryItem(
        id: UUID(),
        content: .text("第一条"),
        capturedAt: Date(timeIntervalSince1970: 200),
        expiresAt: nil,
        isPinned: false
    )
    let second = ClipboardHistoryItem(
        id: UUID(),
        content: .text("第二条"),
        capturedAt: Date(timeIntervalSince1970: 100),
        expiresAt: nil,
        isPinned: false
    )

    #expect(ClipboardHistoryKeyboardNavigation.itemToCopy(in: [first, second], selectedID: nil) == first)
    #expect(ClipboardHistoryKeyboardNavigation.itemToCopy(in: [first, second], selectedID: second.id) == second)
    #expect(ClipboardHistoryKeyboardNavigation.itemToCopy(in: [], selectedID: nil) == nil)
}

@Test("顺序粘贴队列支持单次和循环模式")
func clipboardSequentialPasteQueueAdvancesAndLoops() {
    let first = ClipboardHistoryItem(
        id: UUID(), content: .text("第一"), capturedAt: Date(), expiresAt: nil, isPinned: false
    )
    let second = ClipboardHistoryItem(
        id: UUID(), content: .text("第二"), capturedAt: Date(), expiresAt: nil, isPinned: false
    )
    var once = ClipboardSequentialPasteQueue(items: [first, second], mode: .once)
    #expect(once.next()?.content == .text("第一"))
    #expect(once.next()?.content == .text("第二"))
    #expect(once.next() == nil)
    #expect(!once.isActive)

    var loop = ClipboardSequentialPasteQueue(items: [first, second], mode: .loop)
    #expect(loop.next()?.content == .text("第一"))
    #expect(loop.next()?.content == .text("第二"))
    #expect(loop.next()?.content == .text("第一"))
    #expect(loop.isActive)
}

@Test("剪贴板服务会按选中顺序逐次粘贴队列内容")
@MainActor
func clipboardServicePastesSequentialQueueInOrder() async {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let suiteName = "MenuToolsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var pasteCount = 0
    let service = ClipboardHistoryService(
        limit: 5,
        persistenceURL: nil,
        pasteboard: pasteboard,
        userDefaults: defaults,
        autoPasteAction: {
            pasteCount += 1
            return .pasted
        }
    )
    #expect(service.copy(.text("第一")))
    #expect(service.copy(.text("第二")))
    let orderedIDs = service.items.reversed().map(\.id)

    service.beginSequentialPaste(itemIDs: orderedIDs)
    #expect(service.sequentialPasteProgress?.current == 1)
    #expect(service.pasteNextSequentialItem())
    #expect(pasteboard.string(forType: .string) == "第一")
    #expect(service.pasteNextSequentialItem())
    #expect(pasteboard.string(forType: .string) == "第二")
    #expect(!service.hasActiveSequentialPaste)

    // 自动粘贴在主 Actor 的后续任务中执行。
    for _ in 0 ..< 10 { await Task.yield() }
    #expect(pasteCount == 2)
}

@Test("文本转换支持清理、大小写、合并行、URL 和 JSON")
func clipboardTextTransformsProduceExpectedOutput() {
    #expect(ClipboardTextTransform.trim.apply(to: "  hello  \n") == "hello")
    #expect(ClipboardTextTransform.uppercase.apply(to: "Hello") == "HELLO")
    #expect(ClipboardTextTransform.lowercase.apply(to: "Hello") == "hello")
    #expect(ClipboardTextTransform.joinLines.apply(to: " a\n\n b ") == "a b")
    #expect(ClipboardTextTransform.urlEncode.apply(to: "a b&c") == "a%20b%26c")
    #expect(ClipboardTextTransform.urlDecode.apply(to: "a%20b%26c") == "a b&c")
    #expect(ClipboardTextTransform.formatJSON.apply(to: "{\"b\":2,\"a\":1}")?.contains("\n") == true)
    #expect(ClipboardTextTransform.formatJSON.apply(to: "not json") == nil)
}

@Test("复制历史条目会回到顶部并保留置顶状态")
@MainActor
func clipboardHistoryCopyReinsertsItemAtTop() async throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let persistenceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-ClipboardHistory-Copy-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let service = ClipboardHistoryService(
        limit: 5,
        persistenceURL: persistenceURL,
        pasteboard: pasteboard
    )
    await service.loadPersistedHistory()

    pasteboard.clearContents()
    pasteboard.setString("置顶记录", forType: .string)
    service.refresh()
    let pinnedID = try #require(service.items.first?.id)
    service.togglePinned(id: pinnedID)

    pasteboard.clearContents()
    pasteboard.setString("普通记录", forType: .string)
    service.refresh()

    let pinnedItem = try #require(service.items.first(where: { $0.id == pinnedID }))
    #expect(service.copy(pinnedItem))

    #expect(service.items.map(\.content) == [.text("置顶记录"), .text("普通记录")])
    #expect(service.items.first?.isPinned == true)
    #expect(service.items.count == 2)

    let copiedItem = try #require(service.items.first)
    let persistedItems = ClipboardHistoryPersistence.load(from: persistenceURL)
    #expect(persistedItems.map(\.id) == service.items.map(\.id))
    #expect(persistedItems.map(\.content) == service.items.map(\.content))
    #expect(persistedItems.map(\.isPinned) == service.items.map(\.isPinned))

    service.refresh()

    #expect(service.items.first?.id == copiedItem.id)
    #expect(service.items.first?.capturedAt == copiedItem.capturedAt)
    #expect(service.currentItemCount == (pasteboard.pasteboardItems?.count ?? 0))
}

@Test("复制文字历史会实际写入目标剪贴板")
func clipboardHistoryWritesSelectedTextItem() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))

    #expect(ClipboardHistoryPasteboardWriter.write(.text("可复制内容"), to: pasteboard))
    #expect(pasteboard.string(forType: .string) == "可复制内容")
}

@Test("复制图片历史会实际写入目标剪贴板")
func clipboardHistoryWritesSelectedImageItem() throws {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 2, height: 2).fill()
    image.unlockFocus()

    let imageData = try #require(image.tiffRepresentation)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))

    #expect(ClipboardHistoryPasteboardWriter.write(.image(imageData), to: pasteboard))
    #expect(pasteboard.data(forType: .tiff) != nil)
}

@Test("剪贴板历史可识别网页链接")
func clipboardHistoryReadsURL() {
    let item = NSPasteboardItem()
    item.setString("https://example.com/articles/clipboard", forType: .URL)

    #expect(ClipboardHistoryPasteboardReader.content(from: [item]) == .url(
        "https://example.com/articles/clipboard"
    ))
}

@Test("剪贴板历史可将多个文件合并为一条记录")
func clipboardHistoryReadsMultipleFiles() {
    let first = NSPasteboardItem()
    first.setString(URL(fileURLWithPath: "/tmp/报告.pdf").absoluteString, forType: .fileURL)
    let second = NSPasteboardItem()
    second.setString(URL(fileURLWithPath: "/tmp/截图.png").absoluteString, forType: .fileURL)

    #expect(ClipboardHistoryPasteboardReader.content(from: [first, second]) == .files([
        ClipboardHistoryFile(path: "/tmp/报告.pdf"),
        ClipboardHistoryFile(path: "/tmp/截图.png")
    ]))
}

@Test("链接和多文件历史会实际写回目标剪贴板")
func clipboardHistoryWritesURLAndFiles() {
    let urlPasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    #expect(ClipboardHistoryPasteboardWriter.write(
        .url("https://example.com/clipboard"),
        to: urlPasteboard
    ))
    #expect(urlPasteboard.string(forType: .string) == "https://example.com/clipboard")
    #expect(ClipboardHistoryPasteboardReader.content(from: urlPasteboard.pasteboardItems ?? []) == .url(
        "https://example.com/clipboard"
    ))

    let filePasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let files = [
        ClipboardHistoryFile(path: "/tmp/报告.pdf"),
        ClipboardHistoryFile(path: "/tmp/截图.png")
    ]
    #expect(ClipboardHistoryPasteboardWriter.write(.files(files), to: filePasteboard))
    #expect(ClipboardHistoryPasteboardReader.content(from: filePasteboard.pasteboardItems ?? []) == .files(files))
}

@Test("富文本历史会保留 HTML、RTF 与纯文本粘贴表示")
func clipboardHistoryPreservesRichTextFormats() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let richText = ClipboardRichText(
        plainText: "加粗内容",
        html: Data("<strong>加粗内容</strong>".utf8),
        rtf: Data("{\\rtf1\\b 加粗内容}".utf8)
    )

    #expect(ClipboardHistoryPasteboardWriter.write(.richText(richText), to: pasteboard))
    #expect(pasteboard.string(forType: .string) == richText.plainText)
    #expect(pasteboard.data(forType: .html) == richText.html)
    #expect(pasteboard.data(forType: .rtf) == richText.rtf)
}

@Test("富文本可按纯文本模式写入且不携带 HTML 和 RTF")
func clipboardHistoryCanWriteRichTextAsPlainText() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let richText = ClipboardRichText(
        plainText: "仅保留文字",
        html: Data("<strong>仅保留文字</strong>".utf8),
        rtf: Data("{\\rtf1\\b 仅保留文字}".utf8)
    )

    #expect(ClipboardHistoryPasteboardWriter.write(.richText(richText), to: pasteboard, mode: .plainText))
    #expect(pasteboard.string(forType: .string) == "仅保留文字")
    #expect(pasteboard.data(forType: .html) == nil)
    #expect(pasteboard.data(forType: .rtf) == nil)
}

@Test("无效图片历史复制失败时保留现有剪贴板内容")
func clipboardHistoryDoesNotClearPasteboardForInvalidImage() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("保留内容", forType: .string)

    #expect(!ClipboardHistoryPasteboardWriter.write(.image(Data([0, 1, 2])), to: pasteboard))
    #expect(pasteboard.string(forType: .string) == "保留内容")
}

@Test("图片历史复制前会规范为 TIFF 数据")
func clipboardHistoryImageNormalizesToTIFF() throws {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 2, height: 2).fill()
    image.unlockFocus()

    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))

    let normalized = ClipboardHistoryImageData.tiffData(from: png)

    #expect(normalized != nil)
    #expect(NSImage(data: try #require(normalized)) != nil)
}

@Test("剪贴板历史按最新优先并限制容量")
func historyKeepsNewestItemsWithinLimit() {
    var history = ClipboardHistoryBuffer(limit: 2)
    let now = Date(timeIntervalSince1970: 100)

    history.insert(.text("第一条"), now: now)
    history.insert(.text("第二条"), now: now.addingTimeInterval(1))
    history.insert(.text("第三条"), now: now.addingTimeInterval(2))

    #expect(history.items.map(\.content) == [.text("第三条"), .text("第二条")])
}

@Test("重复内容会移动到历史顶部而不是创建重复项")
func historyDeduplicatesContent() {
    var history = ClipboardHistoryBuffer(limit: 3)
    let now = Date(timeIntervalSince1970: 100)

    history.insert(.text("重复"), now: now)
    history.insert(.text("其他"), now: now.addingTimeInterval(1))
    history.insert(.text("重复"), now: now.addingTimeInterval(2))

    #expect(history.items.map(\.content) == [.text("重复"), .text("其他")])
    #expect(history.items[0].capturedAt == now.addingTimeInterval(2))
}

@Test("固定项目不会被容量淘汰")
func historyPreservesPinnedItems() {
    var history = ClipboardHistoryBuffer(limit: 2)
    let now = Date(timeIntervalSince1970: 100)

    let pinned = history.insert(.text("固定"), now: now)
    #expect(pinned != nil)
    history.togglePinned(id: pinned!.id)
    history.insert(.text("普通一"), now: now.addingTimeInterval(1))
    history.insert(.text("普通二"), now: now.addingTimeInterval(2))

    #expect(history.items.map(\.content) == [.text("普通二"), .text("固定")])
    #expect(history.items[1].isPinned)
}

@Test("验证码和密码内容会标记为敏感并在期限后移除")
func sensitiveTextExpires() {
    var history = ClipboardHistoryBuffer(limit: 5, sensitiveLifetime: 60)
    let now = Date(timeIntervalSince1970: 100)

    let code = history.insert(.text("123456"), now: now)
    #expect(code?.expiresAt == now.addingTimeInterval(60))
    #expect(history.items.count == 1)

    history.pruneExpired(now: now.addingTimeInterval(60))

    #expect(history.items.isEmpty)
}

@Test("图片内容可以加入历史且不会被当作敏感文本")
func imageContentIsRetained() {
    var history = ClipboardHistoryBuffer(limit: 2)
    let data = Data([0, 1, 2, 3])

    let item = history.insert(.image(data), now: Date())

    #expect(item?.content == .image(data))
    #expect(item?.expiresAt == nil)
}

@Test("剪贴板历史可以读取 PNG 图片")
func pasteboardReaderReadsPNGImage() {
    let item = NSPasteboardItem()
    let data = Data([0x89, 0x50, 0x4E, 0x47])
    item.setData(data, forType: .png)

    #expect(ClipboardHistoryPasteboardReader.content(from: item) == .image(data))
}

@Test("剪贴板历史忽略密码管理器声明的隐藏和临时内容")
func pasteboardReaderIgnoresConcealedAndTransientContent() {
    for marker in [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType"
    ] {
        let item = NSPasteboardItem()
        item.setString("不应记录的密码", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))

        #expect(ClipboardHistoryPasteboardReader.content(from: item) == nil)
    }
}

@Test("删除和清空操作只影响对应历史项目")
func historyRemovesRequestedItems() {
    var history = ClipboardHistoryBuffer(limit: 5)
    let now = Date(timeIntervalSince1970: 100)
    let pinned = history.insert(.text("固定"), now: now)
    history.insert(.text("普通"), now: now.addingTimeInterval(1))
    history.togglePinned(id: pinned!.id)

    history.remove(id: pinned!.id)
    history.clearUnpinned()

    #expect(history.items.isEmpty)
}

@Test("清空剪贴板历史会移除普通和固定项目")
func historyClearRemovesAllItems() {
    var history = ClipboardHistoryBuffer(limit: 5)
    let pinned = history.insert(.text("固定"), now: Date())
    history.insert(.text("普通"), now: Date())
    history.togglePinned(id: pinned!.id)

    history.clearAll()

    #expect(history.items.isEmpty)
}

@Test("清空全部历史可在撤销窗口内恢复")
@MainActor
func clipboardHistoryClearAllCanBeUndone() async {
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    )
    #expect(service.copy(.text("第一条")))
    #expect(service.copy(.text("第二条")))

    service.clearHistory()

    #expect(service.items.isEmpty)
    #expect(service.canUndoLastRemoval)
    #expect(service.undoLastRemoval())
    #expect(service.items.map(\.content) == [.text("第二条"), .text("第一条")])
}

@Test("清空系统剪贴板不会删除历史记录")
@MainActor
func clearingSystemPasteboardPreservesHistory() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let service = ClipboardHistoryService(persistenceURL: nil, pasteboard: pasteboard)
    #expect(service.copy(.text("保留的历史")))

    service.clearSystemClipboard()

    #expect(pasteboard.pasteboardItems?.isEmpty != false)
    #expect(service.items.map(\.content) == [.text("保留的历史")])
}

@Test("剪贴板历史可以持久化恢复文本、图片和固定状态")
func historyPersistenceRoundTrips() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-ClipboardHistory-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    var history = ClipboardHistoryBuffer(limit: 5)
    let now = Date(timeIntervalSince1970: 100)
    let text = history.insert(.text("持久化文本"), now: now)
    history.insert(.image(Data([1, 2, 3, 4])), now: now.addingTimeInterval(1))
    history.togglePinned(id: text!.id)

    try ClipboardHistoryPersistence.save(history.items, to: url)
    let restored = ClipboardHistoryPersistence.load(from: url)

    #expect(restored == history.items)
}

@Test("剪贴板历史使用 SQLite 保存元数据并拆分二进制内容")
func historyPersistenceSeparatesMetadataAndBlobs() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-ClipboardHistory-Database-\(UUID().uuidString).sqlite3")
    let blobsURL = ClipboardHistoryPersistence.blobsURL(for: url)
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: blobsURL)
    }
    let item = ClipboardHistoryItem(
        id: UUID(),
        content: .richText(ClipboardRichText(
            plainText: "独立保存",
            html: Data("<b>独立保存</b>".utf8),
            rtf: Data("{\\rtf1 独立保存}".utf8)
        )),
        capturedAt: Date(timeIntervalSince1970: 100),
        expiresAt: nil,
        isPinned: true
    )

    try ClipboardHistoryPersistence.save([item], to: url)

    let databaseHeader = try Data(contentsOf: url).prefix(16)
    #expect(String(data: databaseHeader, encoding: .utf8) == "SQLite format 3\0")
    let blobNames = try FileManager.default.contentsOfDirectory(atPath: blobsURL.path)
    #expect(Set(blobNames) == ["\(item.id.uuidString).html", "\(item.id.uuidString).rtf"])
    let encryptedBlob = try Data(contentsOf: blobsURL.appendingPathComponent("\(item.id.uuidString).html"))
    #expect(encryptedBlob != Data("<b>独立保存</b>".utf8))
    #expect((try Data(contentsOf: url)).range(of: Data("独立保存".utf8)) == nil)
    #expect(ClipboardHistoryPersistence.load(from: url) == [item])
}

@Test("剪贴板历史数据库损坏时会从最近备份恢复")
func historyPersistenceRecoversFromBackup() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-Clipboard-Recovery-\(UUID().uuidString).db")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: ClipboardHistoryPersistence.backupURL(for: url))
        try? FileManager.default.removeItem(at: ClipboardHistoryPersistence.blobsURL(for: url))
    }
    let first = ClipboardHistoryItem(
        id: UUID(), content: .text("第一版"), capturedAt: Date(timeIntervalSince1970: 1_000), expiresAt: nil, isPinned: false
    )
    let second = ClipboardHistoryItem(
        id: UUID(), content: .text("第二版"), capturedAt: Date(timeIntervalSince1970: 2_000), expiresAt: nil, isPinned: false
    )
    try ClipboardHistoryPersistence.save([first], to: url)
    try ClipboardHistoryPersistence.save([second], to: url)
    try Data("损坏".utf8).write(to: url, options: .atomic)

    #expect(ClipboardHistoryPersistence.load(from: url) == [first])
}

@Test("新建的剪贴板数据库会写入当前结构版本")
func historyPersistenceStampsCurrentSchemaVersion() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-Clipboard-Schema-\(UUID().uuidString).sqlite3")
    defer { ClipboardHistoryTemporaryDatabase.remove(url) }

    try ClipboardHistoryPersistence.save([makeTextItem("版本校验")], to: url)

    #expect(try ClipboardHistoryDatabaseProbe.schemaVersion(in: url) == ClipboardHistoryPersistence.currentSchemaVersion)
}

@Test("未写版本号的旧库会在写入时补齐结构与版本")
func historyPersistenceMigratesUnversionedDatabase() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-Clipboard-Unversioned-\(UUID().uuidString).sqlite3")
    defer { ClipboardHistoryTemporaryDatabase.remove(url) }
    try ClipboardHistoryDatabaseProbe.createEmptyDatabase(at: url, version: 0)

    let item = makeTextItem("迁移后写入")
    try ClipboardHistoryPersistence.save([item], to: url)

    #expect(try ClipboardHistoryDatabaseProbe.schemaVersion(in: url) == ClipboardHistoryPersistence.currentSchemaVersion)
    #expect(ClipboardHistoryPersistence.load(from: url).map(\.content) == [.text("迁移后写入")])
}

@Test("结构版本更高的数据库不会被旧版 App 覆盖")
func historyPersistenceRefusesNewerSchemaOnSave() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-Clipboard-NewerSchema-\(UUID().uuidString).sqlite3")
    defer { ClipboardHistoryTemporaryDatabase.remove(url) }

    try ClipboardHistoryPersistence.save([makeTextItem("新版写入")], to: url)
    try ClipboardHistoryDatabaseProbe.setSchemaVersion(99, in: url)

    #expect(throws: (any Error).self) {
        try ClipboardHistoryPersistence.save([makeTextItem("旧版覆盖")], to: url)
    }
    // 版本号与数据都必须原样保留，留给升级后的 App 读取。
    #expect(try ClipboardHistoryDatabaseProbe.schemaVersion(in: url) == 99)
}

@Test("结构版本更高的数据库不会被旧备份覆盖")
func historyPersistenceKeepsNewerDatabaseInsteadOfOlderBackup() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-Clipboard-NewerThanBackup-\(UUID().uuidString).sqlite3")
    defer { ClipboardHistoryTemporaryDatabase.remove(url) }

    // 先写两次，制造一份可用的旧版本备份。
    try ClipboardHistoryPersistence.save([makeTextItem("第一版")], to: url)
    try ClipboardHistoryPersistence.save([makeTextItem("第二版")], to: url)
    try ClipboardHistoryDatabaseProbe.setSchemaVersion(99, in: url)

    #expect(ClipboardHistoryPersistence.load(from: url).isEmpty)
    #expect(try ClipboardHistoryDatabaseProbe.schemaVersion(in: url) == 99)
}

private func makeTextItem(_ text: String) -> ClipboardHistoryItem {
    ClipboardHistoryItem(
        id: UUID(),
        content: .text(text),
        capturedAt: Date(timeIntervalSince1970: 1_000),
        expiresAt: nil,
        isPinned: false
    )
}

/// 直接读写剪贴板数据库文件，用于构造「更高结构版本」这类边界数据。
enum ClipboardHistoryDatabaseProbe {
    struct ProbeError: Error {}

    static func schemaVersion(in url: URL) throws -> Int32 {
        try withDatabase(at: url) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw ProbeError()
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ProbeError() }
            return sqlite3_column_int(statement, 0)
        }
    }

    static func setSchemaVersion(_ version: Int32, in url: URL) throws {
        try withDatabase(at: url) { database in
            guard sqlite3_exec(database, "PRAGMA user_version=\(version)", nil, nil, nil) == SQLITE_OK else {
                throw ProbeError()
            }
        }
    }

    /// 造一个有效的 SQLite 文件，但不建业务表、不写版本号。
    static func createEmptyDatabase(at url: URL, version: Int32) throws {
        try withDatabase(at: url) { database in
            guard sqlite3_exec(database, "PRAGMA user_version=\(version)", nil, nil, nil) == SQLITE_OK else {
                throw ProbeError()
            }
        }
    }

    private static func withDatabase<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ProbeError()
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }
}

enum ClipboardHistoryTemporaryDatabase {
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: ClipboardHistoryPersistence.backupURL(for: url))
        try? FileManager.default.removeItem(at: ClipboardHistoryPersistence.blobsURL(for: url))
    }
}

@Test("旧版 JSON 剪贴板历史会原地迁移到新数据库")
func historyPersistenceMigratesLegacyJSON() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-ClipboardHistory-Legacy-\(UUID().uuidString).json")
    let blobsURL = ClipboardHistoryPersistence.blobsURL(for: url)
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: blobsURL)
    }
    let items = [ClipboardHistoryItem(
        id: UUID(),
        content: .image(Data([1, 2, 3, 4])),
        capturedAt: Date(timeIntervalSince1970: 100),
        expiresAt: nil,
        isPinned: false
    )]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(items).write(to: url)

    #expect(ClipboardHistoryPersistence.load(from: url) == items)
    #expect(String(data: try Data(contentsOf: url).prefix(16), encoding: .utf8) == "SQLite format 3\0")
    #expect(FileManager.default.fileExists(
        atPath: blobsURL.appendingPathComponent("\(items[0].id.uuidString).image").path
    ))
}

@Test("手动标记的敏感内容短时过期且不会持久化")
func manuallyMarkedSensitiveContentExpiresAndIsNotPersisted() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-SensitiveHistory-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let now = Date(timeIntervalSince1970: 100)
    var history = ClipboardHistoryBuffer(limit: 5, sensitiveLifetime: 60)
    let insertedSensitive = history.insert(.text("私人内容"), now: now)
    let sensitive = try #require(insertedSensitive)
    _ = history.insert(.text("普通内容"), now: now.addingTimeInterval(1))

    history.setSensitive(id: sensitive.id, isSensitive: true, now: now)
    let marked = try #require(history.items.first(where: { $0.id == sensitive.id }))
    #expect(marked.isSensitive)
    #expect(marked.expiresAt == now.addingTimeInterval(60))

    let recopiedAt = now.addingTimeInterval(10)
    _ = history.insert(marked.content, now: recopiedAt)
    let recopied = try #require(history.items.first(where: { $0.content == marked.content }))
    #expect(recopied.isSensitive)
    #expect(recopied.expiresAt == recopiedAt.addingTimeInterval(60))

    try ClipboardHistoryPersistence.save(history.items, to: url)
    #expect(ClipboardHistoryPersistence.load(from: url).map(\.content) == [.text("普通内容")])

    history.pruneExpired(now: recopiedAt.addingTimeInterval(60))
    #expect(!history.items.contains(where: { $0.content == marked.content }))
}

@Test("敏感内容不会被全文搜索命中")
func sensitiveContentIsExcludedFromFullTextSearch() {
    let sensitive = ClipboardHistoryItem(
        id: UUID(),
        content: .text("秘密项目代号"),
        capturedAt: Date(),
        expiresAt: nil,
        isPinned: false,
        isSensitive: true
    )

    #expect(ClipboardHistoryList.items(
        from: [sensitive],
        query: "项目代号",
        category: .all,
        sortOrder: .newestFirst
    ).isEmpty)
    #expect(ClipboardHistoryList.items(
        from: [sensitive],
        query: "",
        category: .all,
        sortOrder: .newestFirst
    ) == [sensitive])
}

@Test("历史标题标签和备注可编辑并参与搜索")
@MainActor
func clipboardHistoryMetadataCanBeEditedAndSearched() throws {
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    )
    #expect(service.copy(.text("原始内容")))
    let itemID = try #require(service.items.first?.id)

    service.setTitle("  报销资料  ", for: itemID)
    service.setTags(["财务", " 财务 ", "九月"], for: itemID)
    service.setNote("  等待审批  ", for: itemID)

    let updated = try #require(service.items.first)
    #expect(updated.title == "报销资料")
    #expect(updated.tags == ["九月", "财务"])
    #expect(updated.note == "等待审批")
    for query in ["报销", "九月", "审批"] {
        #expect(ClipboardHistoryList.items(
            from: service.items,
            query: query,
            category: .all,
            sortOrder: .newestFirst
        ) == [updated])
    }

    service.setTitle("   ", for: itemID)
    service.setNote("", for: itemID)
    #expect(service.items.first?.title == nil)
    #expect(service.items.first?.note == nil)
}

@Test("图片 OCR 和二维码结果会进入历史搜索索引")
func imageRecognitionTextIsSearchable() {
    let image = ClipboardHistoryItem(
        id: UUID(),
        content: .image(Data([1, 2, 3])),
        capturedAt: Date(),
        expiresAt: nil,
        isPinned: false,
        recognizedText: "发票号码\nhttps://example.com/receipt"
    )

    #expect(ClipboardHistoryList.items(
        from: [image],
        query: "发票号码",
        category: .all,
        sortOrder: .newestFirst
    ) == [image])
    #expect(image.recognizedURLs == [URL(string: "https://example.com/receipt")!])
}

@Test("图片写入历史后会在后台补充本地识别结果")
@MainActor
func clipboardHistoryRecognizesImageTextAfterInsertion() async throws {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 2, height: 2).fill()
    image.unlockFocus()
    let imageData = try #require(image.tiffRepresentation)
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)")),
        imageTextRecognizer: { _ in .recognized("识别文字\nhttps://example.com/qr") }
    )

    #expect(service.copy(.image(imageData)))
    // 识别经过进程级闸门（actor 跳转 + 可能的排队），用有界轮询而不是固定 yield 次数等待。
    for _ in 0 ..< 200 where service.items.first?.recognizedText == nil {
        try await Task.sleep(for: .milliseconds(25))
    }

    #expect(service.items.first?.recognizedText == "识别文字\nhttps://example.com/qr")
}

@Test("剪贴板历史默认识别器会识别真实二维码")
@MainActor
func clipboardHistoryDefaultRecognizerReadsQRCode() async throws {
    let payload = "https://example.com/clipboard-default-recognizer"
    let imageData = try makeQRCodeData(payload: payload)
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    )

    #expect(service.copy(.image(imageData)))
    for _ in 0 ..< 50 where service.items.first?.recognizedText == nil {
        try await Task.sleep(for: .milliseconds(100))
    }

    #expect(service.items.first?.recognizedText == payload)
}

@Test("剪贴板历史默认识别器会处理批量恢复的二维码")
@MainActor
func clipboardHistoryDefaultRecognizerHandlesRestoredBatch() async throws {
    let payloads = (0 ..< 24).map { "https://example.com/clipboard-restored-\($0)" }
    let items = try payloads.enumerated().map { index, payload in
        ClipboardHistoryItem(
            id: UUID(),
            content: .image(try makeQRCodeData(payload: payload)),
            capturedAt: Date(timeIntervalSince1970: Double(1000 - index)),
            expiresAt: nil,
            isPinned: false
        )
    }
    let persistenceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-ClipboardRecognitionBatch-\(UUID().uuidString).sqlite3")
    defer {
        try? FileManager.default.removeItem(at: persistenceURL)
        try? FileManager.default.removeItem(at: ClipboardHistoryPersistence.blobsURL(for: persistenceURL))
    }
    let service = ClipboardHistoryService(
        limit: 50,
        persistenceURL: persistenceURL,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)")),
        persistenceLoader: { _ in items }
    )

    await service.loadPersistedHistory()
    for _ in 0 ..< 150 where service.items.contains(where: { $0.recognizedText == nil }) {
        try await Task.sleep(for: .milliseconds(100))
    }

    #expect(Set(service.items.compactMap(\.recognizedText)) == Set(payloads))
}

@Test("识别失败的图片会重试并在后续尝试写入结果")
@MainActor
func clipboardHistoryRetriesFailedImageRecognition() async throws {
    let attempts = ClipboardRecognitionAttemptProbe()
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)")),
        imageTextRecognizer: { _ in
            let attempt = await attempts.next()
            return attempt >= 2 ? .recognized("重试后的识别结果") : .failed
        }
    )

    service.importItems([makeImageHistoryItem()])

    for _ in 0 ..< 120 where service.items.first?.recognizedText == nil {
        try await Task.sleep(for: .milliseconds(25))
    }

    #expect(service.items.first?.recognizedText == "重试后的识别结果")
    #expect(await attempts.count >= 2)
    #expect(service.failedImageRecognitionCount == 0)
}

@Test("图上没有文字时不会重复触发识别")
@MainActor
func clipboardHistoryDoesNotRetryImagesWithoutContent() async throws {
    let attempts = ClipboardRecognitionAttemptProbe()
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)")),
        imageTextRecognizer: { _ in
            _ = await attempts.next()
            return .noContent
        }
    )

    service.importItems([makeImageHistoryItem()])
    var waited = 0
    while await attempts.count < 1, waited < 80 {
        try await Task.sleep(for: .milliseconds(25))
        waited += 1
    }
    try await Task.sleep(for: .milliseconds(600))

    #expect(await attempts.count == 1)
    #expect(service.items.first?.recognizedText == nil)
    #expect(service.failedImageRecognitionCount == 0)
}

@Test("识别一直失败的图片会在面板刷新时补试")
@MainActor
func clipboardHistoryRetriesFailedImageRecognitionOnRefresh() async throws {
    let attempts = ClipboardRecognitionAttemptProbe()
    let attemptLimit = ClipboardImageRecognitionPolicy.attemptLimit
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)")),
        imageTextRecognizer: { _ in
            let attempt = await attempts.next()
            return attempt > attemptLimit ? .recognized("刷新后的识别结果") : .failed
        }
    )

    service.importItems([makeImageHistoryItem()])
    var waited = 0
    while await attempts.count < attemptLimit, waited < 200 {
        try await Task.sleep(for: .milliseconds(25))
        waited += 1
    }

    #expect(service.items.first?.recognizedText == nil)
    #expect(service.failedImageRecognitionCount == 1)

    service.refresh()

    for _ in 0 ..< 120 where service.items.first?.recognizedText == nil {
        try await Task.sleep(for: .milliseconds(25))
    }

    #expect(service.items.first?.recognizedText == "刷新后的识别结果")
    #expect(service.failedImageRecognitionCount == 0)
}

@Test("失败的图片识别支持用户手动重试")
@MainActor
func clipboardHistoryRetriesFailedImageRecognitionOnDemand() async throws {
    let attempts = ClipboardRecognitionAttemptProbe()
    let attemptLimit = ClipboardImageRecognitionPolicy.attemptLimit
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)")),
        imageTextRecognizer: { _ in
            let attempt = await attempts.next()
            return attempt > attemptLimit ? .recognized("手动重试结果") : .failed
        }
    )

    service.importItems([makeImageHistoryItem()])
    var waited = 0
    while await attempts.count < attemptLimit, waited < 200 {
        try await Task.sleep(for: .milliseconds(25))
        waited += 1
    }
    #expect(service.failedImageRecognitionCount == 1)
    #expect(service.items.first?.recognizedText == nil)

    service.retryFailedImageRecognitions()

    for _ in 0 ..< 120 where service.items.first?.recognizedText == nil {
        try await Task.sleep(for: .milliseconds(25))
    }

    #expect(service.items.first?.recognizedText == "手动重试结果")
    #expect(service.failedImageRecognitionCount == 0)
}

@Test("多个剪贴板服务实例共用进程级识别闸门")
@MainActor
func clipboardImageRecognitionSerializesAcrossServices() async throws {
    let probe = ClipboardRecognitionConcurrencyProbe()
    let recognizer: @Sendable (Data) async -> ClipboardImageRecognitionOutcome = { _ in
        await probe.enter()
        try? await Task.sleep(for: .milliseconds(150))
        await probe.exit()
        return .recognized("串行识别结果")
    }
    let first = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)")),
        imageTextRecognizer: recognizer
    )
    let second = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)")),
        imageTextRecognizer: recognizer
    )

    first.importItems([makeImageHistoryItem("first")])
    second.importItems([makeImageHistoryItem("second")])

    for _ in 0 ..< 200
    where first.items.first?.recognizedText == nil || second.items.first?.recognizedText == nil {
        try await Task.sleep(for: .milliseconds(25))
    }

    #expect(first.items.first?.recognizedText == "串行识别结果")
    #expect(second.items.first?.recognizedText == "串行识别结果")
    #expect(await probe.peakConcurrency == 1)
}

private func makeImageHistoryItem(_ seed: String = "image") -> ClipboardHistoryItem {
    ClipboardHistoryItem(
        id: UUID(),
        content: .image(Data(seed.utf8)),
        capturedAt: Date(),
        expiresAt: nil,
        isPinned: false
    )
}

private actor ClipboardRecognitionAttemptProbe {
    private var attempts = 0
    var count: Int { attempts }

    func next() -> Int {
        attempts += 1
        return attempts
    }
}

private actor ClipboardRecognitionConcurrencyProbe {
    private var active = 0
    private var peak = 0
    var peakConcurrency: Int { peak }

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func exit() {
        active -= 1
    }
}

private func makeQRCodeData(payload: String) throws -> Data {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(payload.utf8)
    filter.correctionLevel = "M"
    let output = try #require(filter.outputImage?.transformed(
        by: CGAffineTransform(scaleX: 10, y: 10)
    ))
    let context = CIContext()
    let cgImage = try #require(context.createCGImage(output, from: output.extent))
    return try #require(NSBitmapImageRep(cgImage: cgImage).representation(
        using: .png,
        properties: [:]
    ))
}

@Test("剪贴板历史服务使用应用级共享实例")
@MainActor
func historyServiceUsesSharedInstance() {
    #expect(ClipboardHistoryService.shared === ClipboardHistoryService.shared)
}

@Test("暂停记录和排除应用会阻止新剪贴板内容写入历史")
func clipboardRecordingPolicyRespectsPauseAndExcludedApplications() {
    #expect(!ClipboardHistoryRecordingPolicy.shouldRecord(
        isPaused: true,
        sourceBundleID: "com.example.browser",
        excludedBundleIDs: []
    ))
    #expect(!ClipboardHistoryRecordingPolicy.shouldRecord(
        isPaused: false,
        sourceBundleID: "com.example.browser",
        excludedBundleIDs: ["com.example.browser"]
    ))
    #expect(ClipboardHistoryRecordingPolicy.shouldRecord(
        isPaused: false,
        sourceBundleID: "com.example.editor",
        excludedBundleIDs: ["com.example.browser"]
    ))
}

@Test("暂停记录和排除应用配置会持久化")
@MainActor
func clipboardRecordingPreferencesPersist() throws {
    let suiteName = "MenuTools-ClipboardRecordingPreferences-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let service = ClipboardHistoryService(
        persistenceURL: nil,
        userDefaults: defaults
    )
    service.setRecordingPaused(true)
    service.addExcludedBundleID("com.example.browser")

    let restored = ClipboardHistoryService(
        persistenceURL: nil,
        userDefaults: defaults
    )
    #expect(restored.isRecordingPaused)
    #expect(restored.excludedBundleIDs == ["com.example.browser"])
}

@Test("剪贴板历史服务初始化不在主线程同步读取持久化文件")
@MainActor
func historyServiceDefersPersistenceLoad() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-ClipboardHistory-Lazy-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let persisted = [
        ClipboardHistoryItem(
            id: UUID(),
            content: .text("后台恢复"),
            capturedAt: Date(timeIntervalSince1970: 100),
            expiresAt: nil,
            isPinned: false
        )
    ]
    try ClipboardHistoryPersistence.save(persisted, to: url)

    let service = ClipboardHistoryService(persistenceURL: url)

    #expect(service.items.isEmpty)
    #expect(!service.hasLoadedPersistedHistory)

    await service.loadPersistedHistory()

    #expect(service.hasLoadedPersistedHistory)
    #expect(service.items == persisted)
}

@Test("设置历史容量会裁剪内容并保存用户选择")
@MainActor
func historyServicePersistsConfiguredLimit() throws {
    let suiteName = "MenuTools-ClipboardHistory-Limit-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-ClipboardHistory-Limit-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let service = ClipboardHistoryService(limit: 200, persistenceURL: url, userDefaults: defaults)
    service.setLimit(.twenty)

    #expect(service.limit == 20)
    #expect(defaults.integer(forKey: SettingsKey.clipboardHistoryLimit) == 20)
}

@Test("异步恢复期间调整容量会按最新容量恢复历史")
@MainActor
func historyServiceUsesLatestLimitAfterDelayedLoad() async {
    let persisted = (0 ..< 25).map { index in
        ClipboardHistoryItem(
            id: UUID(),
            content: .text("记录 \(index)"),
            capturedAt: Date(timeIntervalSince1970: Double(200 - index)),
            expiresAt: nil,
            isPinned: false
        )
    }
    let gate = ClipboardHistoryLoadGate(items: persisted)
    let service = ClipboardHistoryService(
        limit: 200,
        persistenceURL: URL(fileURLWithPath: "/tmp/MenuTools-ClipboardHistory-Delayed.json"),
        persistenceLoader: { _ in await gate.load() }
    )

    let loadTask = Task { await service.loadPersistedHistory() }
    await gate.waitUntilLoadStarts()
    service.setLimit(.twenty)
    await gate.finishLoading()
    await loadTask.value

    #expect(service.limit == 20)
    #expect(service.items.count == 20)
}

@Test("异步恢复期间清空历史不会被旧文件覆盖")
@MainActor
func historyServiceKeepsClearHistoryDuringDelayedLoad() async {
    let persisted = [
        ClipboardHistoryItem(
            id: UUID(),
            content: .text("旧记录"),
            capturedAt: Date(),
            expiresAt: nil,
            isPinned: false
        )
    ]
    let gate = ClipboardHistoryLoadGate(items: persisted)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-ClipboardHistory-Clear-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let service = ClipboardHistoryService(
        persistenceURL: url,
        persistenceLoader: { _ in await gate.load() }
    )

    let loadTask = Task { await service.loadPersistedHistory() }
    await gate.waitUntilLoadStarts()
    service.clearHistory()
    await gate.finishLoading()
    await loadTask.value

    #expect(service.items.isEmpty)
}

@Test("复制常用片段会写入剪贴板并进入历史")
@MainActor
func clipboardHistoryCopyContentAddsSnippetToHistory() async throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let persistenceURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-ClipboardHistory-Snippet-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let service = ClipboardHistoryService(
        limit: 5,
        persistenceURL: persistenceURL,
        pasteboard: pasteboard
    )
    await service.loadPersistedHistory()

    #expect(service.copy(.text("常用回复")))
    #expect(pasteboard.string(forType: .string) == "常用回复")
    #expect(service.items.map(\.content) == [.text("常用回复")])
}

@Test("暂停记录时手动复制只写入系统剪贴板")
@MainActor
func clipboardHistoryPausedCopyDoesNotAddHistory() async {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let suiteName = "MenuToolsTests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suiteName)!
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: pasteboard,
        userDefaults: preferences
    )

    service.setRecordingPaused(true)

    #expect(service.copy(.text("暂停期间的片段")))
    #expect(pasteboard.string(forType: .string) == "暂停期间的片段")
    #expect(service.items.isEmpty)
}

@Test("排除应用失焦时会丢弃尚未采样的剪贴板变更")
@MainActor
func clipboardHistoryExcludedApplicationDeactivationDiscardsPendingContent() async {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: pasteboard,
        frontmostApplicationBundleIdentifierProvider: { "com.example.normal" }
    )
    await service.loadPersistedHistory()
    service.addExcludedBundleID("com.example.private")

    pasteboard.clearContents()
    pasteboard.setString("私密内容", forType: .string)
    service.handleApplicationDeactivation(bundleIdentifier: "com.example.private")
    service.refresh()

    #expect(service.items.isEmpty)
}

@Test("普通应用失焦时会按离开前的上下文保存待采样变更")
@MainActor
func clipboardHistoryNormalApplicationDeactivationRecordsPendingContent() async {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: pasteboard,
        frontmostApplicationBundleIdentifierProvider: { "com.example.private" }
    )
    await service.loadPersistedHistory()
    service.addExcludedBundleID("com.example.private")

    pasteboard.clearContents()
    pasteboard.setString("普通内容", forType: .string)
    service.handleApplicationDeactivation(bundleIdentifier: "com.example.normal")

    #expect(service.items.map(\.content) == [.text("普通内容")])
}

@Test("自动清理按保留天数、数量和占用空间移除非置顶历史")
func clipboardHistoryCleanupPreservesPinnedItems() {
    let now = Date(timeIntervalSince1970: 10 * 86_400)
    var retentionHistory = ClipboardHistoryBuffer(
        limit: 10,
        retentionDuration: 86_400,
        storageLimitBytes: 1_024
    )
    retentionHistory.insert(.text("旧记录"), now: now.addingTimeInterval(-2 * 86_400))
    retentionHistory.insert(.text("新记录"), now: now)
    #expect(retentionHistory.items.map(\.content) == [.text("新记录")])

    var protectedHistory = ClipboardHistoryBuffer(
        limit: 1,
        retentionDuration: 86_400,
        storageLimitBytes: 4
    )
    let pinned = protectedHistory.insert(.text("置顶"), now: now)!
    protectedHistory.togglePinned(id: pinned.id)
    protectedHistory.insert(.text("12345"), now: now)
    #expect(protectedHistory.items.map(\.content) == [.text("置顶")])
    #expect(protectedHistory.items.first?.isPinned == true)
}

@Test("敏感规则可独立拦截密码管理器、验证码、银行卡和关键词")
func clipboardSensitiveRulesAreIndividuallyConfigurable() {
    var rules = ClipboardSensitiveRules()

    #expect(rules.shouldExclude(.text("123456"), sourceBundleID: nil))
    #expect(rules.shouldExclude(.text("4242 4242 4242 4242"), sourceBundleID: nil))
    #expect(rules.shouldExclude(.text("普通文本"), sourceBundleID: "com.1password.1password"))
    #expect(rules.shouldExclude(
        .richText(ClipboardRichText(
            plainText: "包含 secret 的富文本",
            html: Data("<b>secret</b>".utf8),
            rtf: nil
        )),
        sourceBundleID: nil
    ))
    #expect(rules.shouldExclude(.image(Data([1, 2, 3])), sourceBundleID: "com.bitwarden.desktop"))

    rules.verificationCodesEnabled = false
    rules.bankCardsEnabled = false
    rules.passwordManagersEnabled = false
    rules.keywords = ["仅此关键词"]

    #expect(!rules.shouldExclude(.text("123456"), sourceBundleID: nil))
    #expect(!rules.shouldExclude(.text("4242 4242 4242 4242"), sourceBundleID: nil))
    #expect(!rules.shouldExclude(.text("普通文本"), sourceBundleID: "com.1password.1password"))
    #expect(rules.shouldExclude(.text("包含仅此关键词的内容"), sourceBundleID: nil))
}

@Test("敏感规则支持用户指定应用并兼容旧配置")
func clipboardSensitiveRulesSupportCustomApplications() throws {
    let appBundleID = "com.example.password-vault"
    var rules = ClipboardSensitiveRules()
    rules.applicationBundleIDs = [appBundleID]

    #expect(rules.shouldExclude(.text("普通内容"), sourceBundleID: appBundleID))
    #expect(!rules.shouldExclude(.text("普通内容"), sourceBundleID: "com.example.editor"))

    let data = try JSONEncoder().encode(rules)
    let decoded = try JSONDecoder().decode(ClipboardSensitiveRules.self, from: data)
    #expect(decoded == rules)

    let legacy = #"{"passwordManagersEnabled":true,"verificationCodesEnabled":true,"bankCardsEnabled":true,"keywords":["password"]}"#.data(using: .utf8)!
    let legacyRules = try JSONDecoder().decode(ClipboardSensitiveRules.self, from: legacy)
    #expect(legacyRules.applicationBundleIDs.isEmpty)
}

@Test("开启自动粘贴后复制历史会调用粘贴动作")
@MainActor
func clipboardHistoryAutoPasteCallsConfiguredAction() async {
    let recorder = ClipboardAutoPasteRecorder()
    let feedbackRecorder = ClipboardFeedbackRecorder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: pasteboard,
        autoPasteAction: { recorder.paste() },
        feedbackPresenter: { feedbackRecorder.show($0) }
    )

    service.setAutoPasteAfterCopy(true)
    #expect(service.copy(.text("自动粘贴")))
    #expect(recorder.callCount == 0)
    await Task.yield()
    #expect(recorder.callCount == 1)
    #expect(service.copyFeedback == .pasted)
    #expect(feedbackRecorder.feedbacks == [.pasted])
}

@Test("历史记录支持显式纯文本粘贴且保留原始历史内容")
@MainActor
func clipboardHistoryPerformsExplicitPlainTextPaste() async {
    let recorder = ClipboardAutoPasteRecorder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: pasteboard,
        autoPasteAction: { recorder.paste() }
    )
    let richText = ClipboardRichText(
        plainText: "粘贴文字",
        html: Data("<b>粘贴文字</b>".utf8),
        rtf: nil
    )

    #expect(service.perform(.richText(richText), action: .pastePlainText))
    await Task.yield()

    #expect(recorder.callCount == 1)
    #expect(pasteboard.string(forType: .string) == richText.plainText)
    #expect(pasteboard.data(forType: .html) == nil)
    #expect(service.items.first?.content == .richText(richText))
}

@Test("默认剪贴板动作会持久化并兼容旧自动粘贴开关")
@MainActor
func clipboardPrimaryActionPersistsAndMigratesLegacyPreference() throws {
    let suiteName = "MenuTools-ClipboardPrimaryAction-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "clipboard.autoPasteAfterCopy")

    let migrated = ClipboardHistoryService(persistenceURL: nil, userDefaults: defaults)
    #expect(migrated.primaryAction == .paste)

    migrated.setPrimaryAction(.copy)
    let restored = ClipboardHistoryService(persistenceURL: nil, userDefaults: defaults)
    #expect(restored.primaryAction == .copy)
    #expect(!restored.autoPasteAfterCopy)
}

@Test("自动粘贴目标会忽略自身进程并且只消费一次")
@MainActor
func clipboardAutoPasteTargetTracksPreviousApplication() {
    let tracker = ClipboardAutoPasteTargetTracker()

    tracker.remember(processIdentifier: 100, currentProcessIdentifier: 100)
    #expect(tracker.takeProcessIdentifier() == nil)

    tracker.remember(processIdentifier: 200, currentProcessIdentifier: 100)
    #expect(tracker.takeProcessIdentifier() == 200)
    #expect(tracker.takeProcessIdentifier() == nil)

    tracker.remember(processIdentifier: 200, currentProcessIdentifier: 100)
    tracker.remember(processIdentifier: 100, currentProcessIdentifier: 100)
    #expect(tracker.takeProcessIdentifier() == nil)
}

@Test("自动粘贴结果会转换为用户可见的复制反馈")
func clipboardAutoPasteResultsExposeClearFeedback() {
    #expect(ClipboardCopyFeedback(autoPasteResult: .pasted) == .pasted)
    #expect(ClipboardCopyFeedback(autoPasteResult: .accessibilityPermissionDenied) == .accessibilityPermissionDenied)
    #expect(ClipboardCopyFeedback(autoPasteResult: .noEditableTarget) == .noEditableTarget)
    #expect(ClipboardCopyFeedback(autoPasteResult: .failed) == .pasteFailed)
}

@Test("清理系统剪贴板会区分已清空和本来就为空")
@MainActor
func clipboardClearPublishesFeedback() {
    let recorder = ClipboardFeedbackRecorder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: pasteboard,
        feedbackPresenter: { recorder.show($0) }
    )

    pasteboard.clearContents()
    pasteboard.setString("待清理内容", forType: .string)

    #expect(service.clearSystemClipboard())
    #expect(pasteboard.string(forType: .string) == nil)
    #expect(recorder.feedbacks.last == .clipboardCleared)
    #expect(ClipboardCopyFeedback.clipboardCleared.localizationKey == "status.clipboardCleared")

    #expect(service.clearSystemClipboard() == false)
    #expect(recorder.feedbacks.last == .clipboardAlreadyEmpty)
    #expect(ClipboardCopyFeedback.clipboardAlreadyEmpty.localizationKey == "cleanup.clipboardEmpty")
}

@Test("删除历史支持多选并在短暂窗口内撤销")
@MainActor
func clipboardHistoryMultipleRemovalCanBeUndone() async {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let service = ClipboardHistoryService(persistenceURL: nil, pasteboard: pasteboard)
    await service.loadPersistedHistory()
    #expect(service.copy(.text("第一条")))
    #expect(service.copy(.text("第二条")))
    let removedIDs = Set(service.items.map(\.id))

    service.remove(ids: removedIDs)
    #expect(service.items.isEmpty)
    #expect(service.canUndoLastRemoval)
    #expect(service.undoLastRemoval())
    #expect(service.items.map(\.content) == [.text("第二条"), .text("第一条")])
}

@Test("仅清空非置顶历史也可在撤销窗口内恢复")
@MainActor
func clipboardHistoryClearUnpinnedCanBeUndone() async {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let service = ClipboardHistoryService(persistenceURL: nil, pasteboard: pasteboard)
    await service.loadPersistedHistory()
    #expect(service.copy(.text("置顶内容")))
    let pinnedID = try! #require(service.items.first?.id)
    service.togglePinned(id: pinnedID)
    #expect(service.copy(.text("普通内容")))

    service.clearUnpinnedHistory()

    #expect(service.items.map(\.content) == [.text("置顶内容")])
    #expect(service.canUndoLastRemoval)
    #expect(service.undoLastRemoval())
    #expect(service.items.map(\.content) == [.text("普通内容"), .text("置顶内容")])
}

@Test("历史项目按置顶、今天、昨天和更早日期分组")
func clipboardHistoryDateSectionsGroupItems() {
    let now = Date(timeIntervalSince1970: 10 * 86_400 + 12 * 3_600)
    let items = [
        ClipboardHistoryItem(id: UUID(), content: .text("置顶"), capturedAt: now, expiresAt: nil, isPinned: true),
        ClipboardHistoryItem(id: UUID(), content: .text("今天"), capturedAt: now, expiresAt: nil, isPinned: false),
        ClipboardHistoryItem(id: UUID(), content: .text("昨天"), capturedAt: now.addingTimeInterval(-86_400), expiresAt: nil, isPinned: false),
        ClipboardHistoryItem(id: UUID(), content: .text("更早"), capturedAt: now.addingTimeInterval(-3 * 86_400), expiresAt: nil, isPinned: false)
    ]

    #expect(ClipboardHistoryDateSections.sections(from: items, now: now).map(\.kind) == [
        .pinned,
        .today,
        .yesterday,
        .date(Calendar.current.startOfDay(for: now.addingTimeInterval(-3 * 86_400)))
    ])
}

@MainActor
private final class ClipboardAutoPasteRecorder {
    private(set) var callCount = 0

    func paste() -> ClipboardAutoPasteResult {
        callCount += 1
        return .pasted
    }
}

@MainActor
private final class ClipboardFeedbackRecorder {
    private(set) var feedbacks: [ClipboardCopyFeedback] = []

    func show(_ feedback: ClipboardCopyFeedback) {
        feedbacks.append(feedback)
    }
}

private actor ClipboardHistoryLoadGate {
    private let items: [ClipboardHistoryItem]
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var loadWaiter: CheckedContinuation<Void, Never>?

    init(items: [ClipboardHistoryItem]) {
        self.items = items
    }

    func waitUntilLoadStarts() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    func load() async -> [ClipboardHistoryItem] {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { continuation in
            loadWaiter = continuation
        }
        return items
    }

    func finishLoading() {
        loadWaiter?.resume()
        loadWaiter = nil
    }
}

@Test("剪贴板支持按来源 App 覆盖记录、自动粘贴、保留期限和敏感规则")
@MainActor
func clipboardApplicationPoliciesRoundTrip() {
    let suiteName = "ClipboardApplicationPolicies-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let sensitive = ClipboardSensitiveRules()
    let service = ClipboardHistoryService(
        limit: 10,
        persistenceURL: nil,
        userDefaults: defaults,
        frontmostApplicationBundleIdentifierProvider: { "com.example.editor" }
    )
    let policy = ClipboardApplicationPolicy(
        bundleID: "com.example.editor",
        record: false,
        autoPaste: true,
        retentionDays: 3,
        sensitiveRules: sensitive
    )
    service.setApplicationPolicy(policy)
    #expect(service.applicationPolicy(for: "com.example.editor") == policy)
    #expect(service.effectiveAutoPaste(for: "com.example.editor"))

    let restored = ClipboardHistoryService(limit: 10, persistenceURL: nil, userDefaults: defaults)
    #expect(restored.applicationPolicies == [policy])
    restored.removeApplicationPolicy(for: "com.example.editor")
    #expect(restored.applicationPolicies.isEmpty)
}

@Test("剪贴板历史分页不会越界")
func clipboardHistoryPagingIsBounded() {
    let items = (0..<3).map { ClipboardHistoryItem(id: UUID(), content: .text("\($0)"), capturedAt: Date(), expiresAt: nil, isPinned: false) }
    #expect(Array(ClipboardHistoryList.page(items, offset: 1, pageSize: 2)).count == 2)
    #expect(ClipboardHistoryList.page(items, offset: 3, pageSize: 2).isEmpty)
    #expect(ClipboardHistoryList.page(items, offset: 0, pageSize: 0).isEmpty)
}

@Test("剪贴板文本分析支持代码、Markdown、颜色和结构化行")
func clipboardTextAnalysisRecognizesCommonFormats() {
    let analysis = ClipboardTextAnalysis.analyze("# 标题\nfunc greet() {}\n#FF8800")
    #expect(analysis.codeLanguage == "Swift")
    #expect(analysis.markdownPreview != nil)
    #expect(analysis.colorHex == nil)
    #expect(analysis.structuredLines.count == 3)
    #expect(ClipboardTextAnalysis.analyze("#12AbEF").colorHex == "#12ABEF")
}

@Test("剪贴板搜索索引支持增量更新和删除")
func clipboardHistorySearchIndexUpdatesIncrementally() {
    let first = ClipboardHistoryItem(id: UUID(), content: .text("Alpha"), capturedAt: Date(), expiresAt: nil, isPinned: false)
    let second = ClipboardHistoryItem(id: UUID(), content: .text("Beta"), capturedAt: Date(), expiresAt: nil, isPinned: false)
    var index = ClipboardHistorySearchIndex()
    index.upsert(first)
    #expect(index.matches("alpha", id: first.id))
    #expect(!index.matches("beta", id: first.id))
    index.upsert(second)
    index.remove(first.id)
    #expect(!index.matches("alpha", id: first.id))
    #expect(index.matches("beta", id: second.id))
}

@Test("剪贴板文件历史能够识别 PDF")
func clipboardHistoryFileRecognizesPDF() {
    #expect(ClipboardHistoryFile(path: "/tmp/report.PDF").isPDF)
    #expect(!ClipboardHistoryFile(path: "/tmp/report.txt").isPDF)
}

@Test("PDF 剪贴板内容可以持久化恢复")
func clipboardPDFContentRoundTrips() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard-PDF-\(UUID().uuidString).sqlite3")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: ClipboardHistoryPersistence.blobsURL(for: url))
        try? FileManager.default.removeItem(at: ClipboardHistoryPersistence.backupURL(for: url))
    }
    let item = ClipboardHistoryItem(id: UUID(), content: .pdf(Data("%PDF-1.7".utf8)), capturedAt: Date(timeIntervalSince1970: 1_000), expiresAt: nil, isPinned: false)
    try ClipboardHistoryPersistence.save([item], to: url)
    #expect(ClipboardHistoryPersistence.load(from: url) == [item])
}

@Test("PDF 剪贴板项目能够从系统剪贴板读取并写回")
func clipboardPDFPasteboardRoundTrips() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let pdf = Data("%PDF-1.7 test".utf8)
    #expect(ClipboardHistoryPasteboardWriter.write(.pdf(pdf), to: pasteboard))
    #expect(ClipboardHistoryPasteboardReader.content(from: pasteboard.pasteboardItems ?? []) == .pdf(pdf))
}
