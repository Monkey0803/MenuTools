import CryptoKit
import Foundation

struct ClipboardArchiveDocument: Codable, Equatable, Sendable {
    static let currentFormatVersion = 4
    /// v3 起 historyItems 可能包含删除墓碑；v4 起片段与分组也有墓碑、分组带 updatedAt。
    private static let legacyFormatVersions: Set<Int> = [1, 2, 3]

    var formatVersion: Int
    var createdAt: Date
    var historyItems: [ClipboardHistoryItem]
    var snippetGroups: [ClipboardSnippetGroup]
    var snippets: [ClipboardSnippet]

    static func current(
        historyItems: [ClipboardHistoryItem],
        snippetGroups: [ClipboardSnippetGroup],
        snippets: [ClipboardSnippet],
        createdAt: Date = Date()
    ) -> ClipboardArchiveDocument {
        ClipboardArchiveDocument(
            formatVersion: currentFormatVersion,
            createdAt: createdAt,
            historyItems: historyItems.filter { !$0.isSensitive },
            snippetGroups: snippetGroups,
            snippets: snippets
        )
    }

    func validated() throws -> ClipboardArchiveDocument {
        guard formatVersion == Self.currentFormatVersion || Self.legacyFormatVersions.contains(formatVersion) else {
            throw ClipboardArchiveError.unsupportedVersion
        }
        var document = self
        document.formatVersion = Self.currentFormatVersion
        document.historyItems.removeAll(where: \.isSensitive)
        return document
    }
}

enum ClipboardArchiveError: Error, Equatable, LocalizedError {
    case emptyPassphrase
    case invalidFormat
    case unsupportedVersion
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .emptyPassphrase:
            return L("clipboard.archive.error.emptyPassphrase")
        case .invalidFormat:
            return L("clipboard.archive.error.invalidFormat")
        case .unsupportedVersion:
            return L("clipboard.archive.error.unsupportedVersion")
        case .decryptionFailed:
            return L("clipboard.archive.error.decryptionFailed")
        }
    }
}

/// 使用 PBKDF2-HMAC-SHA256 派生口令密钥，并以 AES-GCM 保护历史与常用片段归档。
enum ClipboardArchiveCrypto {
    private static let magic = Data("MTCLIP01".utf8)
    private static let saltLength = 16
    private static let defaultIterations: UInt32 = 120_000
    private static let maximumAcceptedIterations: UInt32 = 1_000_000

    static func encrypt(
        _ document: ClipboardArchiveDocument,
        passphrase: String,
        iterations: UInt32 = defaultIterations
    ) throws -> Data {
        guard !passphrase.isEmpty else { throw ClipboardArchiveError.emptyPassphrase }
        let validated = try document.validated()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let plaintext = try encoder.encode(validated)
        let saltKey = SymmetricKey(size: .bits128)
        let salt = saltKey.withUnsafeBytes { Data($0) }
        let rounds = max(1, iterations)
        let roundsData = encoded(rounds)
        let authenticatedHeader = magic + roundsData + salt
        let key = deriveKey(passphrase: passphrase, salt: salt, iterations: rounds)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedHeader)
        guard let combined = sealed.combined else { throw ClipboardArchiveError.invalidFormat }
        return authenticatedHeader + combined
    }

    static func decrypt(_ encrypted: Data, passphrase: String) throws -> ClipboardArchiveDocument {
        guard !passphrase.isEmpty else { throw ClipboardArchiveError.emptyPassphrase }
        let headerLength = magic.count + MemoryLayout<UInt32>.size + saltLength
        guard encrypted.count > headerLength,
              encrypted.prefix(magic.count) == magic else {
            throw ClipboardArchiveError.invalidFormat
        }
        let roundsRange = magic.count ..< magic.count + MemoryLayout<UInt32>.size
        let rounds = encrypted[roundsRange].reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        guard rounds > 0, rounds <= maximumAcceptedIterations else {
            throw ClipboardArchiveError.invalidFormat
        }
        let saltRange = roundsRange.upperBound ..< headerLength
        let salt = Data(encrypted[saltRange])
        let authenticatedHeader = Data(encrypted.prefix(headerLength))
        let key = deriveKey(passphrase: passphrase, salt: salt, iterations: rounds)
        do {
            let sealed = try AES.GCM.SealedBox(combined: Data(encrypted.dropFirst(headerLength)))
            let plaintext = try AES.GCM.open(sealed, using: key, authenticating: authenticatedHeader)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(ClipboardArchiveDocument.self, from: plaintext).validated()
        } catch let error as ClipboardArchiveError {
            throw error
        } catch {
            throw ClipboardArchiveError.decryptionFailed
        }
    }

    private static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) -> SymmetricKey {
        let normalized = passphrase.precomposedStringWithCanonicalMapping
        let passwordKey = SymmetricKey(data: Data(normalized.utf8))
        var blockInput = salt
        blockInput.append(contentsOf: [0, 0, 0, 1])
        var previous = Data(HMAC<SHA256>.authenticationCode(for: blockInput, using: passwordKey))
        var result = [UInt8](previous)
        if iterations > 1 {
            for _ in 2 ... iterations {
                previous = Data(HMAC<SHA256>.authenticationCode(for: previous, using: passwordKey))
                for index in result.indices {
                    result[index] ^= previous[index]
                }
            }
        }
        return SymmetricKey(data: result)
    }

    private static func encoded(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}

enum ClipboardSyncMerge {
    static func merge(
        local: ClipboardArchiveDocument,
        remote: ClipboardArchiveDocument,
        now: Date = Date()
    ) -> ClipboardArchiveDocument {
        // 墓碑按 ID 取删除时间较晚的一条：删除动作必须能压过其他设备上仍在的条目。
        var tombstoneCandidates: [UUID: ClipboardHistoryItem] = [:]
        for item in (remote.historyItems + local.historyItems) where item.deletedAt != nil {
            let candidate = item.deletedAt ?? .distantPast
            if let existing = tombstoneCandidates[item.id],
               (existing.deletedAt ?? .distantPast) >= candidate {
                continue
            }
            tombstoneCandidates[item.id] = item
        }

        var historyByID: [UUID: ClipboardHistoryItem] = [:]
        var resurrectedIDs = Set<UUID>()
        for item in (remote.historyItems + local.historyItems) where item.deletedAt == nil {
            guard item.isPinned, !item.isSensitive else { continue }
            if let tombstone = tombstoneCandidates[item.id] {
                // 删除之后重新采集到的同 ID 条目视为复活，否则保持删除状态。
                guard item.capturedAt > (tombstone.deletedAt ?? .distantPast) else { continue }
                resurrectedIDs.insert(item.id)
            }
            if let existing = historyByID[item.id], existing.capturedAt > item.capturedAt { continue }
            historyByID[item.id] = item
        }

        let tombstones = tombstoneCandidates.values
            .filter { !resurrectedIDs.contains($0.id) }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }

        // 分组墓碑：删掉的分组不能被远端带回来。
        var groupTombstones: [UUID: ClipboardSnippetGroup] = [:]
        for group in remote.snippetGroups + local.snippetGroups where group.deletedAt != nil {
            let candidate = group.deletedAt ?? .distantPast
            if let existing = groupTombstones[group.id],
               (existing.deletedAt ?? .distantPast) >= candidate {
                continue
            }
            groupTombstones[group.id] = group
        }

        // 分组本体：名称按 updatedAt 较新者胜出（旧数据没有时间则视为最早）。
        var groupsByID: [UUID: ClipboardSnippetGroup] = [:]
        for group in remote.snippetGroups + local.snippetGroups where group.deletedAt == nil {
            guard groupTombstones[group.id] == nil else { continue }
            if let existing = groupsByID[group.id],
               (existing.updatedAt ?? .distantPast) > (group.updatedAt ?? .distantPast) {
                continue
            }
            groupsByID[group.id] = group
        }

        // 片段墓碑与片段本体，规则与剪贴板历史一致。
        var snippetTombstones: [UUID: ClipboardSnippet] = [:]
        for snippet in remote.snippets + local.snippets where snippet.deletedAt != nil {
            let candidate = snippet.deletedAt ?? .distantPast
            if let existing = snippetTombstones[snippet.id],
               (existing.deletedAt ?? .distantPast) >= candidate {
                continue
            }
            snippetTombstones[snippet.id] = snippet
        }

        var snippetsByID: [UUID: ClipboardSnippet] = [:]
        var revivedSnippetIDs = Set<UUID>()
        for snippet in remote.snippets + local.snippets where snippet.deletedAt == nil {
            if let tombstone = snippetTombstones[snippet.id] {
                guard snippet.updatedAt > (tombstone.deletedAt ?? .distantPast) else { continue }
                revivedSnippetIDs.insert(snippet.id)
            }
            if let existing = snippetsByID[snippet.id], existing.updatedAt > snippet.updatedAt { continue }
            snippetsByID[snippet.id] = snippet
        }

        // 分组被删除后，其片段回到默认分组，保证共享文件本身自洽。
        let liveGroupIDs = Set(groupsByID.keys)
        let snippets = snippetsByID.values.map { snippet in
            guard !liveGroupIDs.contains(snippet.groupID) else { return snippet }
            var moved = snippet
            moved.groupID = ClipboardSnippetStore.defaultGroupID
            return moved
        }
        let groupTombstoneValues = groupTombstones.values
            .filter { groupsByID[$0.id] == nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        let snippetTombstoneValues = snippetTombstones.values
            .filter { !revivedSnippetIDs.contains($0.id) }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }

        return ClipboardArchiveDocument.current(
            historyItems: historyByID.values.sorted { $0.capturedAt > $1.capturedAt } + tombstones,
            snippetGroups: groupsByID.values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                + groupTombstoneValues,
            snippets: snippets.sorted { $0.updatedAt > $1.updatedAt } + snippetTombstoneValues,
            createdAt: now
        )
    }
}

/// 共享文件的读写抽象：默认走本地文件，测试可注入内存实现来制造并发写入时序。
protocol ClipboardSyncFileStoring: Sendable {
    /// 文件不存在返回 nil；存在但读不出来应当抛错（例如 iCloud 还没下载完）。
    func read(at url: URL) throws -> Data?
    func write(_ data: Data, to url: URL) throws
}

struct ClipboardSyncFileStore: ClipboardSyncFileStoring {
    func read(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

enum ClipboardSharedFileSyncError: LocalizedError, Equatable {
    /// 共享文件被其他设备持续改写：已把本机合并结果写到冲突副本。
    case conflictingWrites(conflictURL: URL)

    var errorDescription: String? {
        switch self {
        case let .conflictingWrites(conflictURL):
            return L("clipboard.sync.error.conflict", conflictURL.lastPathComponent)
        }
    }
}

/// 用户可把该文件放在 iCloud Drive、Dropbox 等同步目录；内容始终沿用口令加密格式。
enum ClipboardSharedFileSync {
    /// 写入冲突时的最大重试次数：每次重试都会带着对方的新内容重新合并。
    static let maximumAttempts = 3

    /// 找出与共享文件同目录的冲突副本，供设置页提示用户处理。
    static func conflictCopies(for url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let prefix = "\(url.deletingPathExtension().lastPathComponent).conflict-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// 冲突副本：反复被并发改写时保留本机合并结果，避免覆盖别人的更新。
    static func conflictURL(for url: URL, now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem).conflict-\(formatter.string(from: now))\(suffix)")
    }

    static func synchronize(
        local: ClipboardArchiveDocument,
        at url: URL,
        passphrase: String,
        store: any ClipboardSyncFileStoring = ClipboardSyncFileStore()
    ) throws -> ClipboardArchiveDocument {
        var attempt = 0
        while true {
            attempt += 1
            let remoteData = try store.read(at: url)
            let remote = try remoteData
                .map { try ClipboardArchiveCrypto.decrypt($0, passphrase: passphrase) }
                ?? ClipboardArchiveDocument.current(historyItems: [], snippetGroups: [], snippets: [])
            let merged = ClipboardSyncMerge.merge(local: local, remote: remote)
            let encrypted = try ClipboardArchiveCrypto.encrypt(merged, passphrase: passphrase)

            // 写之前再确认一次文件没有被其他设备改过；改过就带着新内容重新合并，
            // 而不是把对方的更新直接盖掉。
            guard try store.read(at: url) == remoteData else {
                guard attempt < maximumAttempts else {
                    let conflictURL = conflictURL(for: url)
                    try store.write(encrypted, to: conflictURL)
                    throw ClipboardSharedFileSyncError.conflictingWrites(conflictURL: conflictURL)
                }
                continue
            }

            try store.write(encrypted, to: url)
            return merged
        }
    }
}
