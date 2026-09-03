import Foundation
import Testing
@testable import MenuTools

@Test("常用片段会展开日期和当前剪贴板变量")
func clipboardSnippetTemplateExpandsVariables() {
    let date = Date(timeIntervalSince1970: 0)
    #expect(
        ClipboardSnippetTemplate.render(
            "日期 {{date}}，内容 {{clipboard}}",
            clipboardText: "原内容",
            now: date,
            calendar: Calendar(identifier: .gregorian)
        ).contains("原内容")
    )
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
