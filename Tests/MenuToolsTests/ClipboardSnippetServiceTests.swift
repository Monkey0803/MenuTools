import Foundation
import Testing
@testable import MenuTools

@Test("常用片段会展开日期和当前剪贴板变量")
func clipboardSnippetTemplateExpandsVariables() {
    let date = Date(timeIntervalSince1970: 0)
    #expect(
        ClipboardSnippetTemplate.render(
            "日期 {{date}}，时间 {{time}}，内容 {{clipboard}}",
            clipboardText: "原内容",
            now: date,
            calendar: Calendar(identifier: .gregorian)
        ).contains("原内容")
    )
}

@Test("常用片段模板支持显式换行变量")
func clipboardSnippetTemplateExpandsNewline() {
    #expect(
        ClipboardSnippetTemplate.render("第一行{{newline}}第二行", clipboardText: nil)
            .contains("第一行\n第二行")
    )
}

@Test("常用片段支持编辑、移动分组和手动排序")
func clipboardSnippetsCanBeEditedMovedAndReordered() throws {
    var store = ClipboardSnippetStore()
    let work = store.addGroup(name: "工作")
    let personal = store.addGroup(name: "个人")
    let addedFirst = store.addSnippet(title: "第一", content: "A", groupID: work.id)
    let first = try #require(addedFirst)
    let addedSecond = store.addSnippet(title: "第二", content: "B", groupID: work.id)
    let second = try #require(addedSecond)

    let didRenameGroup = store.updateGroup(id: work.id, name: "办公")
    #expect(didRenameGroup)
    let didUpdateSnippet = store.updateSnippet(
        id: first.id,
        title: "已编辑",
        content: "A+",
        groupID: personal.id
    )
    #expect(didUpdateSnippet)
    #expect(store.snippets(in: personal.id).first?.title == "已编辑")

    let didMoveOnlySnippet = store.moveSnippet(id: second.id, direction: .down)
    #expect(didMoveOnlySnippet == false)
    let addedThird = store.addSnippet(title: "第三", content: "C", groupID: work.id)
    let third = try #require(addedThird)
    #expect(store.snippets(in: work.id).map(\.id) == [third.id, second.id])
    let didMoveSecond = store.moveSnippet(id: second.id, direction: .up)
    #expect(didMoveSecond)
    #expect(store.snippets(in: work.id).map(\.id) == [second.id, third.id])
}

@Test("常用片段可按标题和内容搜索")
func clipboardSnippetsCanBeSearched() throws {
    var store = ClipboardSnippetStore()
    let addedFirst = store.addSnippet(
        title: "客服回复",
        content: "感谢您的反馈",
        groupID: ClipboardSnippetStore.defaultGroupID
    )
    let first = try #require(addedFirst)
    _ = store.addSnippet(title: "开发地址", content: "localhost", groupID: ClipboardSnippetStore.defaultGroupID)

    #expect(ClipboardSnippetSearch.results(in: store.allSnippets, query: "反馈") == [first])
}

@Test("常用片段支持标签和收藏状态")
func clipboardSnippetsSupportTagsAndFavorites() throws {
    var store = ClipboardSnippetStore()
    let added = store.addSnippet(
        title: "回复",
        content: "内容",
        groupID: ClipboardSnippetStore.defaultGroupID,
        tags: [" 客服 ", "客服"]
    )
    let snippet = try #require(added)
    #expect(snippet.tags == ["客服"])
    #expect(ClipboardSnippetSearch.results(in: store.allSnippets, query: "客服") == [snippet])

    store.toggleFavorite(id: snippet.id)
    #expect(store.snippets(in: ClipboardSnippetStore.defaultGroupID).first?.isFavorite == true)
}

@Test("常用片段可按分组管理，删除分组后保留到默认分组")
func clipboardSnippetsMoveToDefaultGroupWhenGroupIsRemoved() {
    var store = ClipboardSnippetStore()
    let group = store.addGroup(name: "开发")
    let addedSnippet = store.addSnippet(
        title: "本地地址",
        content: "http://localhost:8080",
        groupID: group.id
    )
    #expect(addedSnippet != nil)
    guard let snippet = addedSnippet else { return }

    #expect(store.snippets(in: group.id) == [snippet])

    store.removeGroup(id: group.id)

    #expect(store.groups.contains(where: { $0.id == ClipboardSnippetStore.defaultGroupID }))
    #expect(store.snippets(in: ClipboardSnippetStore.defaultGroupID) == [
        ClipboardSnippet(
            id: snippet.id,
            groupID: ClipboardSnippetStore.defaultGroupID,
            title: "本地地址",
            content: "http://localhost:8080",
            updatedAt: snippet.updatedAt
        )
    ])
}

@Test("空白片段和空白分组不会写入存储")
func clipboardSnippetStoreRejectsBlankValues() {
    var store = ClipboardSnippetStore()

    #expect(store.addGroup(name: "  ").id == ClipboardSnippetStore.defaultGroupID)
    #expect(store.addSnippet(
        title: "空内容",
        content: "  ",
        groupID: ClipboardSnippetStore.defaultGroupID
    ) == nil)
}

@Test("常用片段可持久化并在重载后保留分组和内容")
func clipboardSnippetsPersistAcrossReload() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-ClipboardSnippets-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    var store = ClipboardSnippetStore()
    let group = store.addGroup(name: "开发")
    let addedSnippet = store.addSnippet(
        title: "本地地址",
        content: "http://localhost:8080",
        groupID: group.id,
        now: Date(timeIntervalSince1970: 1_000)
    )
    let snippet = try #require(addedSnippet)
    try ClipboardSnippetPersistence.save(store, to: url)

    let reloadedStore = ClipboardSnippetPersistence.load(from: url)
    #expect(reloadedStore.groups.contains(group))
    #expect(reloadedStore.snippets(in: group.id) == [snippet])
}

@Test("常用片段持久化失败时会暴露错误状态")
@MainActor
func clipboardSnippetServiceExposesPersistenceErrors() {
    let expectedError = NSError(domain: "ClipboardSnippetTests", code: 42, userInfo: [
        NSLocalizedDescriptionKey: "无法写入片段"
    ])
    let service = ClipboardSnippetService(
        persistenceURL: URL(fileURLWithPath: "/tmp/clipboard-snippets-test.json"),
        persistenceSaver: { _, _ in throw expectedError }
    )

    _ = service.addSnippet(
        title: "测试",
        content: "内容",
        groupID: ClipboardSnippetStore.defaultGroupID
    )

    #expect(service.persistenceErrorMessage == "无法写入片段")
}

@Test("常用片段以密文落盘，磁盘上读不到明文内容")
func clipboardSnippetsAreEncryptedAtRest() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("ClipboardSnippets-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let url = directory.appendingPathComponent("ClipboardSnippets.json")
    let snippet = ClipboardSnippet(
        id: UUID(),
        groupID: ClipboardSnippetStore.defaultGroupID,
        title: "部署令牌",
        content: "TOKEN-SECRET-abc123",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let store = ClipboardSnippetStore(snippets: [snippet])

    try ClipboardSnippetPersistence.save(store, to: url)

    let raw = try Data(contentsOf: url)
    // 明文落盘时这段字符串会直接出现在文件里（用户会把 token/命令存进片段）
    #expect(!String(decoding: raw, as: UTF8.self).contains("TOKEN-SECRET-abc123"))
    #expect(ClipboardHistoryEncryption.isSealed(raw))

    let restored = ClipboardSnippetPersistence.load(from: url)
    let restoredSnippet = try #require(restored.allSnippets.first { $0.id == snippet.id })
    #expect(restoredSnippet.content == "TOKEN-SECRET-abc123")
    #expect(restoredSnippet.title == "部署令牌")
}

@Test("旧版明文片段读得回来，并在服务启动时回写为密文")
@MainActor
func clipboardSnippetsMigrateLegacyPlaintextOnLoad() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("ClipboardSnippetMigrate-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let url = directory.appendingPathComponent("ClipboardSnippets.json")
    let snippet = ClipboardSnippet(
        id: UUID(),
        groupID: ClipboardSnippetStore.defaultGroupID,
        title: "旧片段",
        content: "legacy-snippet-content",
        updatedAt: Date(timeIntervalSince1970: 1_600_000_000)
    )
    // 按旧格式（明文 JSON）写入
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let document = ClipboardSnippetDocument(groups: [], snippets: [snippet])
    try encoder.encode(document).write(to: url)
    #expect(!ClipboardHistoryEncryption.isSealed(try Data(contentsOf: url)))

    // 迁移前：旧文件必须仍然读得回来
    let legacyStore = ClipboardSnippetPersistence.load(from: url)
    #expect(legacyStore.allSnippets.contains { $0.content == "legacy-snippet-content" })

    // 服务启动即回写密文，内容不变
    let service = ClipboardSnippetService(persistenceURL: url)
    #expect(service.snippets.contains { $0.content == "legacy-snippet-content" })

    let migrated = try Data(contentsOf: url)
    #expect(ClipboardHistoryEncryption.isSealed(migrated))
    #expect(ClipboardSnippetPersistence.load(from: url).allSnippets.contains {
        $0.content == "legacy-snippet-content"
    })
}

@Test("启动迁移：明文片段文件就地加密，内容保留且不重复迁移")
func clipboardSnippetPersistenceMigratesPlaintextInPlace() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("ClipboardSnippetStartup-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let url = directory.appendingPathComponent("ClipboardSnippets.json")
    let snippet = ClipboardSnippet(
        id: UUID(),
        groupID: ClipboardSnippetStore.defaultGroupID,
        title: "启动迁移",
        content: "startup-migration-content",
        updatedAt: Date(timeIntervalSince1970: 1_600_000_000)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(ClipboardSnippetDocument(groups: [], snippets: [snippet])).write(to: url)

    #expect(ClipboardSnippetPersistence.migrateLegacyPlaintextIfNeeded(at: url))

    let migrated = try Data(contentsOf: url)
    #expect(ClipboardHistoryEncryption.isSealed(migrated))
    #expect(ClipboardSnippetPersistence.load(from: url).allSnippets.contains {
        $0.content == "startup-migration-content"
    })

    // 已经是密文：不再重复迁移
    #expect(!ClipboardSnippetPersistence.migrateLegacyPlaintextIfNeeded(at: url))
    // 文件不存在：不做任何事
    #expect(!ClipboardSnippetPersistence.migrateLegacyPlaintextIfNeeded(
        at: directory.appendingPathComponent("Missing.json")
    ))
    #expect(!ClipboardSnippetPersistence.migrateLegacyPlaintextIfNeeded(at: nil))
}
