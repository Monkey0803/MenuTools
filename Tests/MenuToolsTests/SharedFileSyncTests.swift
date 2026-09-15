import Foundation
import Testing
@testable import MenuTools

private let testMagic = "MTTEST01"

private struct TestDocument: Codable, Equatable, SharedFileSyncDocument {
    var formatVersion = 1
    var value: String
    var updatedAt: Date

    static var emptySharedDocument: TestDocument {
        TestDocument(value: "", updatedAt: .distantPast)
    }

    static func decryptShared(_ data: Data, passphrase: String) throws -> TestDocument {
        try EncryptedArchiveEnvelope.open(
            TestDocument.self,
            from: data,
            passphrase: passphrase,
            magic: testMagic
        )
    }

    func encryptedShared(passphrase: String) throws -> Data {
        try EncryptedArchiveEnvelope.seal(self, passphrase: passphrase, magic: testMagic)
    }

    func mergedShared(with remote: TestDocument, now: Date) -> TestDocument {
        updatedAt >= remote.updatedAt ? self : remote
    }
}

/// 内存共享文件：可按脚本返回不同内容，用来制造并发写入。
private final class MemoryFileStore: SharedFileStoring, @unchecked Sendable {
    private var contents: Data?
    private var queuedReads: [Data?] = []

    init(contents: Data? = nil) {
        self.contents = contents
    }

    func queue(nextReads: [Data?]) {
        queuedReads = nextReads
    }

    func read(at url: URL) throws -> Data? {
        if !queuedReads.isEmpty {
            return queuedReads.removeFirst()
        }
        return contents
    }

    func write(_ data: Data, to url: URL) throws {
        if url.lastPathComponent.contains(".conflict-") {
            conflictWrites.append(data)
            return
        }
        contents = data
    }

    private(set) var conflictWrites: [Data] = []
    var stored: Data? { contents }
}

@Test("信封往返：同一口令可解密回原文档，布局为 magic + 迭代次数 + 盐")
func envelopeRoundTripsAndLaysOutHeader() throws {
    let document = TestDocument(value: "预设", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    let sealed = try EncryptedArchiveEnvelope.seal(
        document,
        passphrase: "口令",
        magic: testMagic,
        iterations: 1_000
    )

    // 头部：8 字节 magic + 4 字节大端迭代次数 + 16 字节盐
    #expect(String(decoding: sealed.prefix(8), as: UTF8.self) == testMagic)
    let roundsRange = 8 ..< 12
    let rounds = sealed[roundsRange].reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
    #expect(rounds == 1_000)
    #expect(sealed.count > 8 + 4 + 16)

    let opened = try EncryptedArchiveEnvelope.open(
        TestDocument.self,
        from: sealed,
        passphrase: "口令",
        magic: testMagic
    )
    #expect(opened == document)
}

@Test("信封拒绝空口令、错误口令、篡改密文与错误 magic")
func envelopeRejectsInvalidInput() throws {
    let document = TestDocument(value: "内容", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    let sealed = try EncryptedArchiveEnvelope.seal(document, passphrase: "正确口令", magic: testMagic, iterations: 1_000)

    #expect(throws: EncryptedArchiveEnvelopeError.emptyPassphrase) {
        try EncryptedArchiveEnvelope.open(TestDocument.self, from: sealed, passphrase: "", magic: testMagic)
    }
    #expect(throws: EncryptedArchiveEnvelopeError.decryptionFailed) {
        try EncryptedArchiveEnvelope.open(TestDocument.self, from: sealed, passphrase: "错误口令", magic: testMagic)
    }
    #expect(throws: EncryptedArchiveEnvelopeError.invalidFormat) {
        try EncryptedArchiveEnvelope.open(TestDocument.self, from: sealed, passphrase: "正确口令", magic: "MTOther1")
    }
    #expect(throws: EncryptedArchiveEnvelopeError.invalidFormat) {
        try EncryptedArchiveEnvelope.open(TestDocument.self, from: Data(repeating: 1, count: 12), passphrase: "正确口令", magic: testMagic)
    }

    // 篡改密文正文会让 GCM 认证失败
    var tampered = sealed
    let lastIndex = tampered.count - 1
    tampered[lastIndex] ^= 0xFF
    #expect(throws: EncryptedArchiveEnvelopeError.decryptionFailed) {
        try EncryptedArchiveEnvelope.open(TestDocument.self, from: tampered, passphrase: "正确口令", magic: testMagic)
    }

    // 篡改头部的迭代次数同样会被认证拦下
    var headerTampered = sealed
    headerTampered[11] = headerTampered[11] &+ 1
    #expect(throws: EncryptedArchiveEnvelopeError.decryptionFailed) {
        try EncryptedArchiveEnvelope.open(TestDocument.self, from: headerTampered, passphrase: "正确口令", magic: testMagic)
    }
}

@Test("共享目录同步会取较新的远端内容并写回合并结果")
func sharedFileSyncMergesAndWritesBack() throws {
    let url = URL(fileURLWithPath: "/tmp/menutools-shared-test.mttest")
    let older = TestDocument(value: "远端较旧", updatedAt: Date(timeIntervalSince1970: 1_000))
    let newer = TestDocument(value: "本机较新", updatedAt: Date(timeIntervalSince1970: 2_000))
    let store = MemoryFileStore(contents: try older.encryptedShared(passphrase: "口令"))

    let merged = try SharedFileSync.synchronize(
        local: newer,
        at: url,
        passphrase: "口令",
        store: store
    )

    #expect(merged.value == "本机较新")

    // 写回的内容是合并结果，且能被同一口令读回
    let stored = try #require(store.stored)
    let reopened = try TestDocument.decryptShared(stored, passphrase: "口令")
    #expect(reopened.value == "本机较新")
}

@Test("共享文件还不存在时以空文档为基准写入")
func sharedFileSyncWritesWhenFileMissing() throws {
    let url = URL(fileURLWithPath: "/tmp/menutools-shared-missing.mttest")
    let store = MemoryFileStore()
    let local = TestDocument(value: "首次写入", updatedAt: Date(timeIntervalSince1970: 2_000))

    let merged = try SharedFileSync.synchronize(local: local, at: url, passphrase: "口令", store: store)

    #expect(merged.value == "首次写入")
    let stored = try #require(store.stored)
    #expect(try TestDocument.decryptShared(stored, passphrase: "口令").value == "首次写入")
}

@Test("并发写入超过重试上限时写出冲突副本并报错")
func sharedFileSyncWritesConflictCopyOnRepeatedWrites() throws {
    let url = URL(fileURLWithPath: "/tmp/menutools-shared-conflict.mttest")
    let local = TestDocument(value: "本机", updatedAt: Date(timeIntervalSince1970: 2_000))
    let remote = TestDocument(value: "对方", updatedAt: Date(timeIntervalSince1970: 1_000))
    let encryptedRemote = try remote.encryptedShared(passphrase: "口令")
    let store = MemoryFileStore()
    // 每次读取都返回不同内容（对方在持续改写），触发冲突分支
    store.queue(nextReads: [
        encryptedRemote, Data([0x01]),
        encryptedRemote, Data([0x02]),
        encryptedRemote, Data([0x03])
    ])

    var conflictURL: URL?
    do {
        _ = try SharedFileSync.synchronize(local: local, at: url, passphrase: "口令", store: store)
        Issue.record("期望抛出冲突错误")
    } catch let error as SharedFileSyncError {
        guard case let .conflictingWrites(url) = error else {
            Issue.record("期望 conflictingWrites")
            return
        }
        conflictURL = url
    }

    let resolved = try #require(conflictURL)
    #expect(resolved.lastPathComponent.contains(".conflict-"))
    #expect(!store.conflictWrites.isEmpty)
}

@Test("共享文件的冲突副本与冲突路径按文件名规则命名")
func sharedFileConflictNaming() {
    let url = URL(fileURLWithPath: "/tmp/MenuTools-VolumePresets.mtvolsync")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let conflict = SharedFileSync.conflictURL(for: url, now: now)

    #expect(conflict.deletingLastPathComponent().path == "/tmp")
    #expect(conflict.lastPathComponent.hasPrefix("MenuTools-VolumePresets.conflict-"))
    #expect(conflict.pathExtension == "mtvolsync")
}