import AppKit
import Foundation
import Testing
@testable import MenuTools

private func unpinTestDate(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func unpinTestItem(
    id: UUID = UUID(),
    text: String = "共享条目",
    capturedAt: TimeInterval = 100,
    isPinned: Bool,
    updatedAt: TimeInterval? = nil
) -> ClipboardHistoryItem {
    ClipboardHistoryItem(
        id: id,
        content: .text(text),
        capturedAt: unpinTestDate(capturedAt),
        expiresAt: nil,
        isPinned: isPinned,
        updatedAt: updatedAt.map(unpinTestDate)
    )
}

private func unpinTestDocument(_ items: [ClipboardHistoryItem]) -> ClipboardArchiveDocument {
    ClipboardArchiveDocument.current(historyItems: items, snippetGroups: [], snippets: [])
}

// MARK: - 状态时间

@Test("自动识别结果不算用户编辑，手动编辑才算")
func recognizedTextDoesNotRefreshStateTimestamp() throws {
    var buffer = ClipboardHistoryBuffer(limit: 5)
    let item = unpinTestItem(isPinned: false)
    buffer.restore([item])

    buffer.setRecognizedText("识别出的文字", for: item.id)
    #expect(buffer.items.first?.recognizedText == "识别出的文字")
    #expect(buffer.items.first?.updatedAt == nil)

    buffer.updateMetadata(id: item.id, title: .some("手动标题"), now: unpinTestDate(700))
    #expect(buffer.items.first?.updatedAt == unpinTestDate(700))
}

@Test("置顶切换与敏感标记都会刷新状态时间")
func pinAndSensitiveChangesRefreshStateTimestamp() throws {
    var buffer = ClipboardHistoryBuffer(limit: 5)
    let item = unpinTestItem(isPinned: true)
    buffer.restore([item])

    buffer.togglePinned(id: item.id, now: unpinTestDate(800))
    #expect(buffer.items.first?.isPinned == false)
    #expect(buffer.items.first?.updatedAt == unpinTestDate(800))

    buffer.setSensitive(id: item.id, isSensitive: true, now: unpinTestDate(900))
    #expect(buffer.items.first?.updatedAt == unpinTestDate(900))
}

// MARK: - 同步集合与合并

@Test("取消置顶的条目会作为状态载体进入同步集合")
@MainActor
func unpinnedItemJoinsSyncSet() {
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    )
    let item = unpinTestItem(isPinned: true)
    service.importItems([item])

    service.togglePinned(id: item.id)

    #expect(service.items.first?.isPinned == false)
    #expect(service.syncHistoryItems.contains { $0.id == item.id && $0.updatedAt != nil })
}

@Test("合并时较新的取消置顶会压过远端的置顶")
func mergePrefersNewerUnpinnedState() {
    let id = UUID()
    let unpinned = unpinTestItem(id: id, isPinned: false, updatedAt: 500)
    let pinnedRemotely = unpinTestItem(id: id, isPinned: true)

    let merged = ClipboardSyncMerge.merge(
        local: unpinTestDocument([unpinned]),
        remote: unpinTestDocument([pinnedRemotely]),
        now: unpinTestDate(600)
    )

    #expect(merged.historyItems.first { $0.deletedAt == nil }?.isPinned == false)
}

@Test("重新置顶（更新的状态时间）会压过远端的取消置顶")
func mergePrefersNewerPinnedState() {
    let id = UUID()
    let repinned = unpinTestItem(id: id, isPinned: true, updatedAt: 700)
    let unpinnedRemotely = unpinTestItem(id: id, isPinned: false, updatedAt: 500)

    let merged = ClipboardSyncMerge.merge(
        local: unpinTestDocument([repinned]),
        remote: unpinTestDocument([unpinnedRemotely]),
        now: unpinTestDate(800)
    )

    #expect(merged.historyItems.first { $0.deletedAt == nil }?.isPinned == true)
}

@Test("导入远端状态后本机条目会跟着取消置顶")
@MainActor
func importingRemoteUnpinStateApplies() {
    let id = UUID()
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    )
    service.importItems([unpinTestItem(id: id, isPinned: true)])

    service.importItems([unpinTestItem(id: id, isPinned: false, updatedAt: 500)])

    #expect(service.items.first?.isPinned == false)
    #expect(service.items.first?.updatedAt == unpinTestDate(500))
}

@Test("旧的状态不会被远端更早的数据覆盖")
@MainActor
func importingOlderRemoteStateKeepsLocalState() {
    let id = UUID()
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    )
    service.importItems([unpinTestItem(id: id, isPinned: true, updatedAt: 800)])

    service.importItems([unpinTestItem(id: id, isPinned: false, updatedAt: 500)])

    #expect(service.items.first?.isPinned == true)
    #expect(service.items.first?.updatedAt == unpinTestDate(800))
}

// MARK: - 归档格式

@Test("归档格式升到 v5 且 v4 文档仍可解码")
func unpinArchiveFormatVersionAcceptsLegacy() throws {
    #expect(ClipboardArchiveDocument.currentFormatVersion == 5)

    let legacyV4 = ClipboardArchiveDocument(
        formatVersion: 4,
        createdAt: unpinTestDate(100),
        historyItems: [unpinTestItem(isPinned: true)],
        snippetGroups: [],
        snippets: []
    )
    #expect(try legacyV4.validated().formatVersion == 5)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    var legacyDocument = unpinTestDocument([unpinTestItem(isPinned: true)])
    legacyDocument.formatVersion = 4
    let data = try encoder.encode(legacyDocument)
    #expect(!String(decoding: data, as: UTF8.self).contains("updatedAt"))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let decoded = try decoder.decode(ClipboardArchiveDocument.self, from: data)
    #expect(decoded.historyItems.first?.updatedAt == nil)
}

@Test("状态时间会随历史持久化并在重启后保留")
@MainActor
func stateTimestampPersistsAcrossReload() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-Unpin-\(UUID().uuidString).sqlite3")
    defer { ClipboardHistoryTemporaryDatabase.remove(url) }

    let first = ClipboardHistoryService(
        persistenceURL: url,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    )
    let item = unpinTestItem(text: "取消置顶的内容", capturedAt: Date().timeIntervalSince1970, isPinned: true)
    first.importItems([item])
    first.togglePinned(id: item.id)
    let unpinnedAt = try #require(first.items.first?.updatedAt)

    let second = ClipboardHistoryService(
        persistenceURL: url,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    )
    await second.loadPersistedHistory()

    #expect(second.items.first?.isPinned == false)
    // 数据库按毫秒存时间戳，比较时留出毫秒级误差。
    let reloaded = try #require(second.items.first?.updatedAt)
    #expect(abs(reloaded.timeIntervalSince(unpinnedAt)) < 0.001)
}
