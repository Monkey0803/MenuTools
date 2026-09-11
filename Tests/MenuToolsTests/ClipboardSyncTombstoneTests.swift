import AppKit
import Foundation
import Testing
@testable import MenuTools

private func tombstoneTestDate(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func tombstoneTestItem(
    id: UUID = UUID(),
    text: String,
    capturedAt: TimeInterval,
    isPinned: Bool = true,
    deletedAt: TimeInterval? = nil
) -> ClipboardHistoryItem {
    ClipboardHistoryItem(
        id: id,
        content: .text(text),
        capturedAt: tombstoneTestDate(capturedAt),
        expiresAt: nil,
        isPinned: isPinned,
        deletedAt: deletedAt.map(tombstoneTestDate)
    )
}

// MARK: - 缓存层的墓碑

@Test("只有删除置顶条目才留墓碑")
func bufferRecordsTombstonesOnlyForPinnedItems() {
    var buffer = ClipboardHistoryBuffer(limit: 10)
    let pinned = tombstoneTestItem(text: "置顶", capturedAt: 100, isPinned: true)
    let plain = tombstoneTestItem(text: "普通", capturedAt: 200, isPinned: false)
    buffer.restore([pinned, plain])

    buffer.remove(id: plain.id, now: tombstoneTestDate(300))
    #expect(buffer.tombstones.isEmpty)
    #expect(buffer.items.count == 1)

    buffer.remove(id: pinned.id, now: tombstoneTestDate(400))
    #expect(buffer.items.isEmpty)
    #expect(buffer.tombstones.count == 1)
    #expect(buffer.tombstones.first?.id == pinned.id)
    #expect(buffer.tombstones.first?.deletedAt == tombstoneTestDate(400))
}

@Test("墓碑不携带内容，避免图片等数据残留")
func tombstoneDropsContent() throws {
    var buffer = ClipboardHistoryBuffer(limit: 10)
    let image = ClipboardHistoryItem(
        id: UUID(),
        content: .image(Data(repeating: 7, count: 4_096)),
        capturedAt: tombstoneTestDate(100),
        expiresAt: nil,
        isPinned: true
    )
    buffer.restore([image])

    buffer.remove(id: image.id, now: tombstoneTestDate(200))

    let tombstone = try #require(buffer.tombstones.first)
    #expect(tombstone.content.storageSize == 0)
}

@Test("墓碑超过保留期会被清理")
func tombstonesExpireAfterRetention() {
    var buffer = ClipboardHistoryBuffer(limit: 10)
    let pinned = tombstoneTestItem(text: "置顶", capturedAt: 100, isPinned: true)
    buffer.restore([pinned])
    buffer.remove(id: pinned.id, now: tombstoneTestDate(200))

    buffer.applyAutomaticCleanup(now: tombstoneTestDate(200 + ClipboardHistoryBuffer.tombstoneRetention - 60))
    #expect(buffer.tombstones.count == 1)

    buffer.applyAutomaticCleanup(now: tombstoneTestDate(200 + ClipboardHistoryBuffer.tombstoneRetention + 60))
    #expect(buffer.tombstones.isEmpty)
}

@Test("恢复条目会清掉对应墓碑")
func restoringItemClearsItsTombstone() {
    var buffer = ClipboardHistoryBuffer(limit: 10)
    let pinned = tombstoneTestItem(text: "置顶", capturedAt: 100, isPinned: true)
    buffer.restore([pinned])
    buffer.remove(id: pinned.id, now: tombstoneTestDate(200))
    #expect(buffer.tombstones.count == 1)

    buffer.restore([pinned], now: tombstoneTestDate(300))

    #expect(buffer.items.map(\.id) == [pinned.id])
    #expect(buffer.tombstones.isEmpty)
}

@Test("应用远端墓碑会删除本地条目并保留墓碑")
func applyingRemoteTombstoneDeletesLocalItem() {
    var buffer = ClipboardHistoryBuffer(limit: 10)
    let pinned = tombstoneTestItem(text: "置顶", capturedAt: 100, isPinned: true)
    buffer.restore([pinned])

    buffer.applyTombstones([tombstoneTestItem(
        id: pinned.id,
        text: "",
        capturedAt: 100,
        isPinned: true,
        deletedAt: 500
    )], now: tombstoneTestDate(510))

    #expect(buffer.items.isEmpty)
    #expect(buffer.tombstones.map(\.id) == [pinned.id])
}

@Test("晚于墓碑重新采集的同 ID 条目不会被删除")
func tombstoneDoesNotDeleteItemRecapturedLater() {
    var buffer = ClipboardHistoryBuffer(limit: 10)
    let recaptured = tombstoneTestItem(text: "重新采集", capturedAt: 600, isPinned: true)
    buffer.restore([recaptured])

    buffer.applyTombstones([tombstoneTestItem(
        id: recaptured.id,
        text: "",
        capturedAt: 100,
        isPinned: true,
        deletedAt: 500
    )], now: tombstoneTestDate(510))

    #expect(buffer.items.map(\.id) == [recaptured.id])
    // 复活后不再保留墓碑，且必须不是因为被保留期裁掉。
    #expect(buffer.tombstones.isEmpty)
    #expect(tombstoneTestDate(510).timeIntervalSince(tombstoneTestDate(500)) < ClipboardHistoryBuffer.tombstoneRetention)
}

// MARK: - 合并语义

@Test("合并时本地删除的置顶条目不会被远端带回来")
func mergeKeepsLocalDeletion() {
    let id = UUID()
    let remoteItem = tombstoneTestItem(id: id, text: "远端仍在置顶", capturedAt: 100)
    let localTombstone = tombstoneTestItem(id: id, text: "", capturedAt: 100, deletedAt: 400)

    let merged = ClipboardSyncMerge.merge(
        local: ClipboardArchiveDocument.current(
            historyItems: [localTombstone],
            snippetGroups: [],
            snippets: []
        ),
        remote: ClipboardArchiveDocument.current(
            historyItems: [remoteItem],
            snippetGroups: [],
            snippets: []
        ),
        now: tombstoneTestDate(500)
    )

    #expect(merged.historyItems.filter { $0.deletedAt == nil }.isEmpty)
    #expect(merged.historyItems.filter { $0.deletedAt != nil }.count == 1)
}

@Test("合并会把删除墓碑继续传给其他设备")
func mergePropagatesTombstones() {
    let id = UUID()
    let localItem = tombstoneTestItem(id: id, text: "本地还留着", capturedAt: 100)
    let remoteTombstone = tombstoneTestItem(id: id, text: "", capturedAt: 100, deletedAt: 400)

    let merged = ClipboardSyncMerge.merge(
        local: ClipboardArchiveDocument.current(historyItems: [localItem], snippetGroups: [], snippets: []),
        remote: ClipboardArchiveDocument.current(historyItems: [remoteTombstone], snippetGroups: [], snippets: []),
        now: tombstoneTestDate(500)
    )

    #expect(merged.historyItems.filter { $0.deletedAt == nil }.isEmpty)
    #expect(merged.historyItems.contains { $0.deletedAt == tombstoneTestDate(400) })
}

// MARK: - 服务层导入

@Test("导入远端墓碑会删掉本机对应历史")
@MainActor
func importingRemoteTombstoneDeletesHistory() {
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    )
    let now = Date()
    let pinned = tombstoneTestItem(
        text: "会被远端删除",
        capturedAt: now.addingTimeInterval(-600).timeIntervalSince1970
    )
    service.importItems([pinned])
    #expect(service.items.map(\.id) == [pinned.id])

    service.importItems([tombstoneTestItem(
        id: pinned.id,
        text: "",
        capturedAt: now.addingTimeInterval(-600).timeIntervalSince1970,
        deletedAt: now.addingTimeInterval(-60).timeIntervalSince1970
    )])

    #expect(service.items.isEmpty)
    #expect(service.syncHistoryItems.contains { $0.deletedAt != nil })
}

@Test("本机删除置顶条目后会写进同步集合")
@MainActor
func deletingPinnedItemJoinsSyncSet() {
    let service = ClipboardHistoryService(
        persistenceURL: nil,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    )
    let pinned = tombstoneTestItem(text: "置顶内容", capturedAt: 100)
    service.importItems([pinned])

    service.remove(ids: [pinned.id])

    #expect(service.items.isEmpty)
    #expect(service.syncHistoryItems.contains { $0.id == pinned.id && $0.deletedAt != nil })
}

@Test("删除墓碑会持久化并在重启后恢复")
@MainActor
func tombstonesPersistAcrossReload() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-Clipboard-Tombstone-\(UUID().uuidString).sqlite3")
    defer { ClipboardHistoryTemporaryDatabase.remove(url) }

    let first = ClipboardHistoryService(
        persistenceURL: url,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    )
    let pinned = tombstoneTestItem(text: "置顶会被删", capturedAt: Date().timeIntervalSince1970)
    first.importItems([pinned])
    first.remove(ids: [pinned.id])
    #expect(first.syncHistoryItems.contains { $0.deletedAt != nil })

    let second = ClipboardHistoryService(
        persistenceURL: url,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("MenuToolsTests.\(UUID().uuidString)"))
    )
    await second.loadPersistedHistory()

    #expect(second.items.isEmpty)
    #expect(second.syncHistoryItems.contains { $0.id == pinned.id && $0.deletedAt != nil })
}

// MARK: - 归档格式

@Test("归档格式升到 v3 且旧版本仍可解码")
func archiveFormatVersionAcceptsLegacy() throws {
    #expect(ClipboardArchiveDocument.currentFormatVersion == 3)

    let legacyV2 = ClipboardArchiveDocument(
        formatVersion: 2,
        createdAt: tombstoneTestDate(100),
        historyItems: [tombstoneTestItem(text: "旧格式条目", capturedAt: 50)],
        snippetGroups: [],
        snippets: []
    )
    #expect(try legacyV2.validated().formatVersion == 3)

    // v2 写出的 JSON 里没有 deletedAt 字段（nil 不参与编码），解码后必须是 nil。
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    var legacyDocument = ClipboardArchiveDocument.current(
        historyItems: [tombstoneTestItem(text: "旧格式条目", capturedAt: 50)],
        snippetGroups: [],
        snippets: []
    )
    legacyDocument.formatVersion = 2
    let data = try encoder.encode(legacyDocument)
    #expect(!String(decoding: data, as: UTF8.self).contains("deletedAt"))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let decoded = try decoder.decode(ClipboardArchiveDocument.self, from: data)
    #expect(decoded.formatVersion == 2)
    #expect(decoded.historyItems.first?.deletedAt == nil)
}
