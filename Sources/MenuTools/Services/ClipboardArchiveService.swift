import CryptoKit
import Foundation

struct ClipboardArchiveDocument: Codable, Equatable, Sendable {
    static let currentFormatVersion = 5
    /// v3 起 historyItems 可能包含删除墓碑；v4 起片段与分组也有墓碑、分组带 updatedAt；
    /// v5 起历史条目带 updatedAt，取消置顶靠状态载体传播。
    private static let legacyFormatVersions: Set<Int> = [1, 2, 3, 4]

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

/// 剪贴板归档的口令加密：复用通用信封，magic 固定为 MTCLIP01。
enum ClipboardArchiveCrypto {
    private static let magic = "MTCLIP01"

    static func encrypt(
        _ document: ClipboardArchiveDocument,
        passphrase: String,
        iterations: UInt32 = EncryptedArchiveEnvelope.defaultIterations
    ) throws -> Data {
        do {
            return try EncryptedArchiveEnvelope.seal(
                try document.validated(),
                passphrase: passphrase,
                magic: magic,
                iterations: iterations
            )
        } catch let error as EncryptedArchiveEnvelopeError {
            throw archiveError(error)
        }
    }

    static func decrypt(_ encrypted: Data, passphrase: String) throws -> ClipboardArchiveDocument {
        do {
            let document = try EncryptedArchiveEnvelope.open(
                ClipboardArchiveDocument.self,
                from: encrypted,
                passphrase: passphrase,
                magic: magic
            )
            return try document.validated()
        } catch let error as EncryptedArchiveEnvelopeError {
            throw archiveError(error)
        }
    }

    private static func archiveError(_ error: EncryptedArchiveEnvelopeError) -> ClipboardArchiveError {
        switch error {
        case .emptyPassphrase: return .emptyPassphrase
        case .invalidFormat: return .invalidFormat
        case .decryptionFailed: return .decryptionFailed
        }
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
            // 取消置顶的条目也要参与比较，否则它的状态会被远端的置顶副本压回去。
            guard !item.isSensitive else { continue }
            if let tombstone = tombstoneCandidates[item.id] {
                // 删除之后重新采集到的同 ID 条目视为复活，否则保持删除状态。
                guard item.capturedAt > (tombstone.deletedAt ?? .distantPast) else { continue }
                resurrectedIDs.insert(item.id)
            }
            // 置顶状态与用户编辑都看状态时间；采集时间只在没有编辑时才起作用。
            if let existing = historyByID[item.id], existing.stateTimestamp > item.stateTimestamp { continue }
            historyByID[item.id] = item
        }

        let tombstones = tombstoneCandidates.values
            .filter { !resurrectedIDs.contains($0.id) }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }

        // 取消置顶的条目本身不在置顶集合里，必须作为状态载体一起合并与传递。
        let unpinCarriers = historyByID.values
            .filter { !$0.isPinned && $0.updatedAt != nil }
            .sorted { $0.stateTimestamp > $1.stateTimestamp }
            .prefix(ClipboardHistoryBuffer.tombstoneLimit)
            .map { $0 }

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
            historyItems: historyByID.values
                .filter(\.isPinned)
                .sorted { $0.capturedAt > $1.capturedAt }
                + tombstones
                + unpinCarriers,
            snippetGroups: groupsByID.values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                + groupTombstoneValues,
            snippets: snippets.sorted { $0.updatedAt > $1.updatedAt } + snippetTombstoneValues,
            createdAt: now
        )
    }
}

/// 剪贴板沿用通用共享文件读写实现（历史命名保留，测试与调用方无需改动）。
typealias ClipboardSyncFileStoring = SharedFileStoring
typealias ClipboardSyncFileStore = SharedFileStore

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
    /// 写入冲突时的最大重试次数（与通用实现一致）。
    static let maximumAttempts = SharedFileSync.maximumAttempts

    static func conflictCopies(for url: URL) -> [URL] {
        SharedFileSync.conflictCopies(for: url)
    }

    static func conflictURL(for url: URL, now: Date = Date()) -> URL {
        SharedFileSync.conflictURL(for: url, now: now)
    }

    static func synchronize(
        local: ClipboardArchiveDocument,
        at url: URL,
        passphrase: String,
        store: any SharedFileStoring = SharedFileStore()
    ) throws -> ClipboardArchiveDocument {
        do {
            return try SharedFileSync.synchronize(
                local: local,
                at: url,
                passphrase: passphrase,
                store: store
            )
        } catch let error as SharedFileSyncError {
            switch error {
            case let .conflictingWrites(conflictURL):
                throw ClipboardSharedFileSyncError.conflictingWrites(conflictURL: conflictURL)
            }
        }
    }
}

extension ClipboardArchiveDocument: SharedFileSyncDocument {
    static var emptySharedDocument: ClipboardArchiveDocument {
        ClipboardArchiveDocument.current(historyItems: [], snippetGroups: [], snippets: [])
    }

    static func decryptShared(_ data: Data, passphrase: String) throws -> ClipboardArchiveDocument {
        try ClipboardArchiveCrypto.decrypt(data, passphrase: passphrase)
    }

    func encryptedShared(passphrase: String) throws -> Data {
        try ClipboardArchiveCrypto.encrypt(self, passphrase: passphrase)
    }

    func mergedShared(with remote: ClipboardArchiveDocument, now: Date) -> ClipboardArchiveDocument {
        ClipboardSyncMerge.merge(local: self, remote: remote, now: now)
    }
}
