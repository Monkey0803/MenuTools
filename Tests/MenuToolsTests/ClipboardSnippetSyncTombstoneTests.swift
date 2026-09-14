import Foundation
import Testing
@testable import MenuTools

private func snippetTestDate(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func snippetTestGroup(
    _ name: String,
    id: UUID = UUID(),
    updatedAt: TimeInterval? = nil,
    deletedAt: TimeInterval? = nil
) -> ClipboardSnippetGroup {
    ClipboardSnippetGroup(
        id: id,
        name: name,
        updatedAt: updatedAt.map(snippetTestDate),
        deletedAt: deletedAt.map(snippetTestDate)
    )
}

private func snippetTestSnippet(
    _ title: String,
    groupID: UUID,
    id: UUID = UUID(),
    updatedAt: TimeInterval = 100,
    deletedAt: TimeInterval? = nil
) -> ClipboardSnippet {
    ClipboardSnippet(
        id: id,
        groupID: groupID,
        title: title,
        content: "正文",
        updatedAt: snippetTestDate(updatedAt),
        deletedAt: deletedAt.map(snippetTestDate)
    )
}

private func snippetTestDocument(
    groups: [ClipboardSnippetGroup],
    snippets: [ClipboardSnippet]
) -> ClipboardArchiveDocument {
    ClipboardArchiveDocument.current(historyItems: [], snippetGroups: groups, snippets: snippets)
}

// MARK: - 存储层墓碑

@Test("删除片段会留下墓碑，且不再出现在列表里")
func snippetStoreRecordsTombstoneOnDelete() throws {
    var store = ClipboardSnippetStore()
    let group = store.addGroup(name: "工作")
    let added = store.addSnippet(title: "片段", content: "正文", groupID: group.id)
    let snippet = try #require(added)

    store.removeSnippet(id: snippet.id, now: snippetTestDate(500))

    #expect(store.allSnippets.isEmpty)
    #expect(store.snippetTombstones.map(\.id) == [snippet.id])
    #expect(store.snippetTombstones.first?.deletedAt == snippetTestDate(500))
    #expect(store.snippetTombstones.first?.content.isEmpty == true)
}

@Test("删除分组会把组内片段移回默认分组，并留下分组墓碑")
func snippetStoreRecordsGroupTombstoneAndReassignsSnippets() throws {
    var store = ClipboardSnippetStore()
    let group = store.addGroup(name: "工作")
    let added = store.addSnippet(title: "片段", content: "正文", groupID: group.id)
    let snippet = try #require(added)

    store.removeGroup(id: group.id, now: snippetTestDate(600))

    #expect(!store.groups.contains { $0.id == group.id })
    #expect(store.groupTombstones.map(\.id) == [group.id])
    #expect(store.allSnippets.map(\.id) == [snippet.id])
    #expect(store.allSnippets.first?.groupID == ClipboardSnippetStore.defaultGroupID)
}

// MARK: - 合并

@Test("合并时本地删除的片段不会被远端带回来")
func snippetMergeKeepsLocalDeletion() {
    let groupID = UUID()
    let snippetID = UUID()
    let remoteSnippet = snippetTestSnippet("远端还留着", groupID: groupID, id: snippetID)
    let localTombstone = snippetTestSnippet(
        "",
        groupID: groupID,
        id: snippetID,
        deletedAt: 400
    )
    let group = snippetTestGroup("工作", id: groupID)

    let merged = ClipboardSyncMerge.merge(
        local: snippetTestDocument(groups: [group], snippets: [localTombstone]),
        remote: snippetTestDocument(groups: [group], snippets: [remoteSnippet]),
        now: snippetTestDate(500)
    )

    #expect(merged.snippets.filter { $0.deletedAt == nil }.isEmpty)
    #expect(merged.snippets.contains { $0.deletedAt != nil })
}

@Test("合并会把片段墓碑继续传给其他设备")
func snippetMergePropagatesTombstone() {
    let groupID = UUID()
    let snippetID = UUID()
    let localSnippet = snippetTestSnippet("本机还留着", groupID: groupID, id: snippetID)
    let remoteTombstone = snippetTestSnippet("", groupID: groupID, id: snippetID, deletedAt: 400)
    let group = snippetTestGroup("工作", id: groupID)

    let merged = ClipboardSyncMerge.merge(
        local: snippetTestDocument(groups: [group], snippets: [localSnippet]),
        remote: snippetTestDocument(groups: [group], snippets: [remoteTombstone]),
        now: snippetTestDate(500)
    )

    #expect(merged.snippets.filter { $0.deletedAt == nil }.isEmpty)
    #expect(merged.snippets.contains { $0.deletedAt == snippetTestDate(400) })
}

@Test("合并会删除被墓碑标记的分组并把其片段移回默认分组")
func snippetMergeAppliesGroupTombstoneAndReassignsSnippets() throws {
    let groupID = UUID()
    // 本地已删除该分组，远端仍带着分组和组内片段。
    let localGroupTombstone = snippetTestGroup("", id: groupID, deletedAt: 400)
    let remoteGroup = snippetTestGroup("工作", id: groupID)
    let remoteSnippet = snippetTestSnippet("组内片段", groupID: groupID, updatedAt: 300)

    let merged = ClipboardSyncMerge.merge(
        local: snippetTestDocument(groups: [localGroupTombstone], snippets: []),
        remote: snippetTestDocument(groups: [remoteGroup], snippets: [remoteSnippet]),
        now: snippetTestDate(500)
    )

    #expect(!merged.snippetGroups.contains { $0.id == groupID && $0.deletedAt == nil })
    let mergedSnippet = try #require(merged.snippets.first { $0.deletedAt == nil })
    #expect(mergedSnippet.groupID != groupID)
}

@Test("分组重命名按更新时间较新的一方胜出")
func snippetMergePicksNewerGroupName() {
    let groupID = UUID()
    let stale = snippetTestGroup("旧名字", id: groupID, updatedAt: 100)
    let renamed = snippetTestGroup("新名字", id: groupID, updatedAt: 200)

    let merged = ClipboardSyncMerge.merge(
        local: snippetTestDocument(groups: [stale], snippets: []),
        remote: snippetTestDocument(groups: [renamed], snippets: []),
        now: snippetTestDate(500)
    )

    #expect(merged.snippetGroups.first { $0.id == groupID }?.name == "新名字")

    let reversed = ClipboardSyncMerge.merge(
        local: snippetTestDocument(groups: [renamed], snippets: []),
        remote: snippetTestDocument(groups: [stale], snippets: []),
        now: snippetTestDate(500)
    )
    #expect(reversed.snippetGroups.first { $0.id == groupID }?.name == "新名字")
}

// MARK: - 服务层

@Test("片段墓碑会持久化并在重启后仍在同步集合里")
@MainActor
func snippetTombstonesPersistAcrossReload() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-Snippet-Tombstone-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let first = ClipboardSnippetService(persistenceURL: url)
    let group = first.addGroup(name: "工作")
    let added = first.addSnippet(title: "片段", content: "正文", groupID: group.id)
    let snippet = try #require(added)
    first.removeSnippet(id: snippet.id)
    #expect(first.syncSnippets.contains { $0.deletedAt != nil })

    let second = ClipboardSnippetService(persistenceURL: url)
    #expect(second.snippets.isEmpty)
    #expect(second.syncSnippets.contains { $0.id == snippet.id && $0.deletedAt != nil })
}

@Test("同步导入会应用远端片段墓碑并保留本机墓碑")
@MainActor
func snippetServiceAppliesRemoteTombstones() throws {
    let service = ClipboardSnippetService(persistenceURL: nil)
    let group = service.addGroup(name: "工作")
    let added = service.addSnippet(title: "会被远端删除", content: "正文", groupID: group.id)
    let removed = try #require(added)

    // 墓碑时间必须晚于本机片段的 updatedAt，否则会被当成「删除后又编辑过」。
    let deletedAt = Date().addingTimeInterval(60)
    service.importSynced(
        groups: [],
        snippets: [snippetTestSnippet(
            "",
            groupID: group.id,
            id: removed.id,
            updatedAt: Date().timeIntervalSince1970,
            deletedAt: deletedAt.timeIntervalSince1970
        )]
    )

    #expect(service.snippets.isEmpty)
    #expect(service.syncSnippets.contains { $0.id == removed.id && $0.deletedAt != nil })
}

// MARK: - 归档格式

@Test("归档格式升到 v4 且 v3 文档仍可解码")
func snippetArchiveFormatVersionAcceptsLegacy() throws {
    #expect(ClipboardArchiveDocument.currentFormatVersion == 4)

    let legacyV3 = ClipboardArchiveDocument(
        formatVersion: 3,
        createdAt: snippetTestDate(100),
        historyItems: [],
        snippetGroups: [snippetTestGroup("工作")],
        snippets: []
    )
    #expect(try legacyV3.validated().formatVersion == 4)

    // v3 写出的 JSON 里没有 deletedAt 字段，解码后必须为 nil。
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    var legacyDocument = snippetTestDocument(
        groups: [snippetTestGroup("工作")],
        snippets: [snippetTestSnippet("片段", groupID: UUID())]
    )
    legacyDocument.formatVersion = 3
    let data = try encoder.encode(legacyDocument)
    let json = String(decoding: data, as: UTF8.self)
    #expect(!json.contains("deletedAt"))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let decoded = try decoder.decode(ClipboardArchiveDocument.self, from: data)
    #expect(decoded.formatVersion == 3)
    #expect(decoded.snippets.first?.deletedAt == nil)
    #expect(decoded.snippetGroups.first?.deletedAt == nil)
}


@Test("收藏切换会刷新更新时间，因此能同步给其他设备")
func snippetFavoriteToggleUpdatesTimestamp() throws {
    var store = ClipboardSnippetStore()
    let group = store.addGroup(name: "工作")
    let added = store.addSnippet(title: "片段", content: "正文", groupID: group.id)
    let snippet = try #require(added)

    store.toggleFavorite(id: snippet.id, now: snippetTestDate(900))

    let toggled = try #require(store.allSnippets.first { $0.id == snippet.id })
    #expect(toggled.isFavorite)
    #expect(toggled.updatedAt == snippetTestDate(900))
}
