import CryptoKit
import Foundation

struct ClipboardArchiveDocument: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

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
        guard formatVersion == Self.currentFormatVersion else {
            throw ClipboardArchiveError.unsupportedVersion
        }
        var document = self
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
        var historyByID: [UUID: ClipboardHistoryItem] = [:]
        for item in (remote.historyItems + local.historyItems) where item.isPinned && !item.isSensitive {
            if let existing = historyByID[item.id], existing.capturedAt > item.capturedAt { continue }
            historyByID[item.id] = item
        }

        var groupsByID = Dictionary(uniqueKeysWithValues: remote.snippetGroups.map { ($0.id, $0) })
        for group in local.snippetGroups { groupsByID[group.id] = group }

        var snippetsByID: [UUID: ClipboardSnippet] = [:]
        for snippet in remote.snippets + local.snippets {
            if let existing = snippetsByID[snippet.id], existing.updatedAt > snippet.updatedAt { continue }
            snippetsByID[snippet.id] = snippet
        }

        return ClipboardArchiveDocument.current(
            historyItems: historyByID.values.sorted { $0.capturedAt > $1.capturedAt },
            snippetGroups: groupsByID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            snippets: snippetsByID.values.sorted { $0.updatedAt > $1.updatedAt },
            createdAt: now
        )
    }
}

/// 用户可把该文件放在 iCloud Drive、Dropbox 等同步目录；内容始终沿用口令加密格式。
enum ClipboardSharedFileSync {
    static func synchronize(
        local: ClipboardArchiveDocument,
        at url: URL,
        passphrase: String
    ) throws -> ClipboardArchiveDocument {
        let remote: ClipboardArchiveDocument
        if FileManager.default.fileExists(atPath: url.path) {
            remote = try ClipboardArchiveCrypto.decrypt(Data(contentsOf: url), passphrase: passphrase)
        } else {
            remote = ClipboardArchiveDocument.current(historyItems: [], snippetGroups: [], snippets: [])
        }
        let merged = ClipboardSyncMerge.merge(local: local, remote: remote)
        let encrypted = try ClipboardArchiveCrypto.encrypt(merged, passphrase: passphrase)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encrypted.write(to: url, options: .atomic)
        return merged
    }
}
