import Foundation
import Testing
@testable import MenuTools

/// 内存文件存储，用来精确制造「读之后、写之前被别的设备改过」的时序。
private final class ClipboardSyncMemoryStore: ClipboardSyncFileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var readCount = 0
    /// 在第 N 次读取之后替换文件内容，模拟一次并发写入。
    private var mutationAfterRead: (readNumber: Int, path: String, data: Data)?
    /// 每次读取之后都替换文件内容（内容逐个变化），模拟持续争用。
    private var mutationOnEveryRead: (path: String, variants: [Data])?

    func read(at url: URL) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        let data = files[url.path]
        if let mutation = mutationAfterRead, mutation.readNumber == readCount {
            files[mutation.path] = mutation.data
        }
        if let mutation = mutationOnEveryRead, !mutation.variants.isEmpty {
            files[mutation.path] = mutation.variants[(readCount - 1) % mutation.variants.count]
        }
        return data
    }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        files[url.path] = data
    }

    func seed(_ data: Data, at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        files[url.path] = data
    }

    func data(at url: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return files[url.path]
    }

    func mutate(afterRead number: Int, at url: URL, to data: Data) {
        lock.lock()
        defer { lock.unlock() }
        mutationAfterRead = (number, url.path, data)
    }

    func mutateOnEveryRead(at url: URL, to variants: [Data]) {
        lock.lock()
        defer { lock.unlock() }
        mutationOnEveryRead = (url.path, variants)
    }
}

private let syncTestPassphrase = "sync-test-passphrase"

private func syncTestItem(_ text: String, capturedAt: TimeInterval) -> ClipboardHistoryItem {
    ClipboardHistoryItem(
        id: UUID(),
        content: .text(text),
        capturedAt: Date(timeIntervalSince1970: capturedAt),
        expiresAt: nil,
        isPinned: true
    )
}

private func syncTestDocument(_ items: [ClipboardHistoryItem], createdAt: TimeInterval = 1_000) -> ClipboardArchiveDocument {
    ClipboardArchiveDocument.current(
        historyItems: items,
        snippetGroups: [],
        snippets: [],
        createdAt: Date(timeIntervalSince1970: createdAt)
    )
}

private func syncTestEncrypted(_ document: ClipboardArchiveDocument) throws -> Data {
    // 测试里用较低轮数，避免 PBKDF2 拖慢用例。
    try ClipboardArchiveCrypto.encrypt(document, passphrase: syncTestPassphrase, iterations: 1_000)
}

@Test("写入前发现文件被其他设备改过会重新合并而不是覆盖")
func sharedFileSyncRetriesWhenFileChangedBeforeWrite() throws {
    let url = URL(fileURLWithPath: "/tmp/MenuTools-Clipboard.mtclipsync")
    let store = ClipboardSyncMemoryStore()
    let remote = syncTestDocument([syncTestItem("远端已有", capturedAt: 100)])
    store.seed(try syncTestEncrypted(remote), at: url)

    // 第一次读取之后，模拟另一台设备刚追加了一条。
    var concurrent = remote
    concurrent.historyItems.append(syncTestItem("另一台设备刚写入", capturedAt: 200))
    store.mutate(afterRead: 1, at: url, to: try syncTestEncrypted(concurrent))

    let merged = try ClipboardSharedFileSync.synchronize(
        local: syncTestDocument([syncTestItem("本机新增", capturedAt: 300)]),
        at: url,
        passphrase: syncTestPassphrase,
        store: store
    )

    // 三边内容都必须保住：本机新增、远端已有、并发写入的那条。
    let texts = Set(merged.historyItems.compactMap(\.content.searchableText))
    #expect(texts == ["本机新增", "远端已有", "另一台设备刚写入"])

    let finalData = try #require(store.data(at: url))
    let finalDocument = try ClipboardArchiveCrypto.decrypt(finalData, passphrase: syncTestPassphrase)
    #expect(Set(finalDocument.historyItems.compactMap(\.content.searchableText)) == texts)
}

@Test("反复被并发改写时会写出冲突副本并报错")
func sharedFileSyncWritesConflictCopyWhenContentionPersists() throws {
    let url = URL(fileURLWithPath: "/tmp/MenuTools-Clipboard.mtclipsync")
    let store = ClipboardSyncMemoryStore()
    let remote = syncTestDocument([syncTestItem("远端已有", capturedAt: 100)])
    store.seed(try syncTestEncrypted(remote), at: url)

    // 每次读取后都改成不同的内容，制造持续争用（内容相同的话第二次就能收敛）。
    let variants = try (1 ... 6).map { round -> Data in
        var document = remote
        document.historyItems.append(syncTestItem("持续改写 \(round)", capturedAt: 200))
        return try syncTestEncrypted(document)
    }
    store.mutateOnEveryRead(at: url, to: variants)

    // 冲突副本的路径带真实时间戳，所以从抛出的错误里取，而不是自己算。
    var reportedConflictURL: URL?
    do {
        _ = try ClipboardSharedFileSync.synchronize(
            local: syncTestDocument([syncTestItem("本机新增", capturedAt: 300)]),
            at: url,
            passphrase: syncTestPassphrase,
            store: store
        )
        Issue.record("持续争用时应当抛出冲突错误")
    } catch let error as ClipboardSharedFileSyncError {
        guard case let .conflictingWrites(conflictURL) = error else {
            Issue.record("冲突错误类型不符：\(error)")
            return
        }
        reportedConflictURL = conflictURL
    }

    let conflictURL = try #require(reportedConflictURL)
    #expect(conflictURL.lastPathComponent.hasPrefix("MenuTools-Clipboard.conflict-"))
    let conflictData = try #require(store.data(at: conflictURL))
    let conflictDocument = try ClipboardArchiveCrypto.decrypt(conflictData, passphrase: syncTestPassphrase)
    #expect(conflictDocument.historyItems.contains { $0.content.searchableText == "本机新增" })
}

@Test("冲突副本文件名带时间戳且与同步文件同目录")
func conflictCopyURLKeepsDirectoryAndTimestamp() {
    let url = URL(fileURLWithPath: "/tmp/shared/MenuTools-Clipboard.mtclipsync")
    let conflictURL = ClipboardSharedFileSync.conflictURL(
        for: url,
        now: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(conflictURL.deletingLastPathComponent().path == "/tmp/shared")
    #expect(conflictURL.lastPathComponent.hasPrefix("MenuTools-Clipboard.conflict-"))
    #expect(conflictURL.pathExtension == "mtclipsync")
}


@Test("能找出共享文件旁的冲突副本，忽略无关文件")
func conflictCopiesListsOnlyMatchingFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuTools-ConflictProbe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let syncURL = directory.appendingPathComponent("MenuTools-Clipboard.mtclipsync")
    let first = directory.appendingPathComponent("MenuTools-Clipboard.conflict-20260911-153000.mtclipsync")
    let second = directory.appendingPathComponent("MenuTools-Clipboard.conflict-20260912-090000.mtclipsync")
    try Data("a".utf8).write(to: syncURL)
    try Data("b".utf8).write(to: first)
    try Data("c".utf8).write(to: second)
    try Data("d".utf8).write(to: directory.appendingPathComponent("其他文件.txt"))

    let copies = ClipboardSharedFileSync.conflictCopies(for: syncURL)

    #expect(copies.map(\.lastPathComponent) == [first.lastPathComponent, second.lastPathComponent])
}
