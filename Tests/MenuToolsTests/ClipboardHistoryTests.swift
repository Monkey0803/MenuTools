import AppKit
import Foundation
import Testing
@testable import MenuTools

@Test("宽屏剪贴板设置页优先使用双列历史卡片")
func clipboardSettingsUsesAdaptiveHistoryGrid() {
    #expect(ClipboardHistorySettingsLayout.columnCount(for: 552) == 2)
    #expect(ClipboardHistorySettingsLayout.columnCount(for: 390) == 1)
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
    let defaults = UserDefaults.standard
    let previousLimit = defaults.object(forKey: SettingsKey.clipboardHistoryLimit)
    defer {
        if let previousLimit {
            defaults.set(previousLimit, forKey: SettingsKey.clipboardHistoryLimit)
        } else {
            defaults.removeObject(forKey: SettingsKey.clipboardHistoryLimit)
        }
    }

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-ClipboardHistory-Limit-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let service = ClipboardHistoryService(limit: 200, persistenceURL: url)
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

    rules.verificationCodesEnabled = false
    rules.bankCardsEnabled = false
    rules.passwordManagersEnabled = false
    rules.keywords = ["仅此关键词"]

    #expect(!rules.shouldExclude(.text("123456"), sourceBundleID: nil))
    #expect(!rules.shouldExclude(.text("4242 4242 4242 4242"), sourceBundleID: nil))
    #expect(!rules.shouldExclude(.text("普通文本"), sourceBundleID: "com.1password.1password"))
    #expect(rules.shouldExclude(.text("包含仅此关键词的内容"), sourceBundleID: nil))
}

@Test("开启自动粘贴后复制历史会调用粘贴动作")
@MainActor
func clipboardHistoryAutoPasteCallsConfiguredAction() async {
    let recorder = ClipboardAutoPasteRecorder()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: pasteboard,
        autoPasteAction: { recorder.paste() }
    )

    service.setAutoPasteAfterCopy(true)
    #expect(service.copy(.text("自动粘贴")))
    #expect(recorder.callCount == 0)
    await Task.yield()
    #expect(recorder.callCount == 1)
}

@Test("自动粘贴结果会转换为用户可见的复制反馈")
func clipboardAutoPasteResultsExposeClearFeedback() {
    #expect(ClipboardCopyFeedback(autoPasteResult: .pasted) == .pasted)
    #expect(ClipboardCopyFeedback(autoPasteResult: .accessibilityPermissionDenied) == .accessibilityPermissionDenied)
    #expect(ClipboardCopyFeedback(autoPasteResult: .noEditableTarget) == .noEditableTarget)
    #expect(ClipboardCopyFeedback(autoPasteResult: .failed) == .pasteFailed)
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
