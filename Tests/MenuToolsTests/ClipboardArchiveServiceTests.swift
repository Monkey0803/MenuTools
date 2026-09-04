import Foundation
import Testing
@testable import MenuTools

@Test("剪贴板归档使用口令加密并完整恢复历史和片段")
func clipboardArchiveEncryptsAndRestoresContent() throws {
    let group = ClipboardSnippetGroup(id: UUID(), name: "工作")
    let item = ClipboardHistoryItem(
        id: UUID(),
        content: .text("仅归档可见的秘密内容"),
        capturedAt: Date(timeIntervalSince1970: 100),
        expiresAt: nil,
        isPinned: true,
        title: "标题",
        tags: ["标签"],
        note: "备注"
    )
    let snippet = ClipboardSnippet(
        id: UUID(),
        groupID: group.id,
        title: "回复",
        content: "片段正文",
        updatedAt: Date(timeIntervalSince1970: 200)
    )
    let document = ClipboardArchiveDocument.current(
        historyItems: [item],
        snippetGroups: [group],
        snippets: [snippet],
        createdAt: Date(timeIntervalSince1970: 300)
    )

    let encrypted = try ClipboardArchiveCrypto.encrypt(document, passphrase: "correct horse", iterations: 10)
    #expect(!encrypted.contains(Data("仅归档可见的秘密内容".utf8)))
    #expect(try ClipboardArchiveCrypto.decrypt(encrypted, passphrase: "correct horse") == document)
}

@Test("剪贴板归档拒绝空口令和错误口令")
func clipboardArchiveRejectsInvalidPassphrases() throws {
    let document = ClipboardArchiveDocument.current(
        historyItems: [],
        snippetGroups: [],
        snippets: [],
        createdAt: Date(timeIntervalSince1970: 300)
    )

    #expect(throws: ClipboardArchiveError.emptyPassphrase) {
        try ClipboardArchiveCrypto.encrypt(document, passphrase: "", iterations: 10)
    }
    let encrypted = try ClipboardArchiveCrypto.encrypt(document, passphrase: "right", iterations: 10)
    #expect(throws: ClipboardArchiveError.decryptionFailed) {
        try ClipboardArchiveCrypto.decrypt(encrypted, passphrase: "wrong")
    }
    var hostile = encrypted
    hostile.replaceSubrange(8 ..< 12, with: [0xFF, 0xFF, 0xFF, 0xFF])
    #expect(throws: ClipboardArchiveError.invalidFormat) {
        try ClipboardArchiveCrypto.decrypt(hostile, passphrase: "right")
    }
}

@Test("剪贴板归档不会包含敏感历史")
func clipboardArchiveExcludesSensitiveHistory() throws {
    let sensitive = ClipboardHistoryItem(
        id: UUID(),
        content: .text("一次性密码"),
        capturedAt: Date(),
        expiresAt: Date().addingTimeInterval(60),
        isPinned: false,
        isSensitive: true
    )
    let ordinary = ClipboardHistoryItem(
        id: UUID(),
        content: .text("普通内容"),
        capturedAt: Date(),
        expiresAt: nil,
        isPinned: false
    )

    let document = ClipboardArchiveDocument.current(
        historyItems: [sensitive, ordinary],
        snippetGroups: [],
        snippets: []
    )
    #expect(document.historyItems == [ordinary])
}

@Test("导入剪贴板归档会合并历史并替换片段分组")
@MainActor
func clipboardArchiveAppliesToServices() throws {
    let history = ClipboardHistoryService(limit: 5, persistenceURL: nil)
    #expect(history.copy(.text("已有历史")))
    let imported = ClipboardHistoryItem(
        id: UUID(),
        content: .text("导入历史"),
        capturedAt: Date().addingTimeInterval(100),
        expiresAt: nil,
        isPinned: true
    )
    history.importItems([imported])
    #expect(history.items.map(\.content) == [.text("导入历史"), .text("已有历史")])

    let group = ClipboardSnippetGroup(id: UUID(), name: "导入分组")
    let snippet = ClipboardSnippet(
        id: UUID(),
        groupID: group.id,
        title: "导入片段",
        content: "正文",
        updatedAt: Date()
    )
    let snippets = ClipboardSnippetService(persistenceURL: nil)
    snippets.replaceImported(groups: [group], snippets: [snippet])
    #expect(snippets.groups.contains(group))
    #expect(snippets.snippets == [snippet])
}

@Test("共享文件同步只合并置顶历史并保留较新的片段")
func clipboardSyncMergesPinnedHistoryAndLatestSnippets() {
    let localPinned = ClipboardHistoryItem(
        id: UUID(), content: .text("本地置顶"), capturedAt: Date(timeIntervalSince1970: 200),
        expiresAt: nil, isPinned: true
    )
    let localUnpinned = ClipboardHistoryItem(
        id: UUID(), content: .text("本地普通"), capturedAt: Date(timeIntervalSince1970: 300),
        expiresAt: nil, isPinned: false
    )
    let remotePinned = ClipboardHistoryItem(
        id: UUID(), content: .text("远端置顶"), capturedAt: Date(timeIntervalSince1970: 100),
        expiresAt: nil, isPinned: true
    )
    let group = ClipboardSnippetGroup(id: UUID(), name: "共享")
    let snippetID = UUID()
    let localSnippet = ClipboardSnippet(
        id: snippetID, groupID: group.id, title: "新版", content: "new",
        updatedAt: Date(timeIntervalSince1970: 200)
    )
    let remoteSnippet = ClipboardSnippet(
        id: snippetID, groupID: group.id, title: "旧版", content: "old",
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let local = ClipboardArchiveDocument.current(
        historyItems: [localPinned, localUnpinned], snippetGroups: [group], snippets: [localSnippet]
    )
    let remote = ClipboardArchiveDocument.current(
        historyItems: [remotePinned], snippetGroups: [group], snippets: [remoteSnippet]
    )

    let merged = ClipboardSyncMerge.merge(local: local, remote: remote)

    #expect(merged.historyItems.map(\.id) == [localPinned.id, remotePinned.id])
    #expect(merged.snippets == [localSnippet])
}

@Test("共享文件同步会以生产轮数写入并读取真实加密文件")
func clipboardSharedFileSyncUsesEncryptedFile() throws {
    let syncURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-ClipboardSync-\(UUID().uuidString).mtclipsync")
    defer { try? FileManager.default.removeItem(at: syncURL) }
    let marker = "共享文件中的测试内容"
    let pinned = ClipboardHistoryItem(
        id: UUID(),
        content: .text(marker),
        capturedAt: Date(timeIntervalSince1970: 500),
        expiresAt: nil,
        isPinned: true
    )
    let local = ClipboardArchiveDocument.current(
        historyItems: [pinned],
        snippetGroups: [],
        snippets: [],
        createdAt: Date(timeIntervalSince1970: 600)
    )

    let merged = try ClipboardSharedFileSync.synchronize(
        local: local,
        at: syncURL,
        passphrase: "integration-passphrase"
    )
    let encrypted = try Data(contentsOf: syncURL)

    #expect(merged.historyItems == [pinned])
    #expect(!encrypted.contains(Data(marker.utf8)))
    #expect(try ClipboardArchiveCrypto.decrypt(
        encrypted,
        passphrase: "integration-passphrase"
    ).historyItems == [pinned])
    #expect(throws: ClipboardArchiveError.decryptionFailed) {
        try ClipboardArchiveCrypto.decrypt(encrypted, passphrase: "wrong-passphrase")
    }
}
