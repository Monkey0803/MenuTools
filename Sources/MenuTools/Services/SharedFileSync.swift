import CryptoKit
import Foundation

/// 口令加密信封的错误。
enum EncryptedArchiveEnvelopeError: Error, Equatable, Sendable {
    case emptyPassphrase
    case invalidFormat
    case decryptionFailed
}

/// 口令加密的 JSON 归档信封：PBKDF2-HMAC-SHA256 派生密钥 + AES-GCM。
///
/// 字节布局：magic(8 字节) + 迭代次数(4 字节大端) + 盐(16 字节) + AES-GCM combined。
/// 头部参与 GCM 认证，因此 magic/迭代次数/盐被篡改都会解密失败。
/// 剪贴板同步与音量预设同步共用这套信封，各自用不同 magic 区分。
enum EncryptedArchiveEnvelope {
    static let magicLength = 8
    static let saltLength = 16
    static let defaultIterations: UInt32 = 120_000
    static let maximumAcceptedIterations: UInt32 = 1_000_000

    static func seal<T: Encodable>(
        _ value: T,
        passphrase: String,
        magic: String,
        iterations: UInt32 = defaultIterations
    ) throws -> Data {
        guard !passphrase.isEmpty else { throw EncryptedArchiveEnvelopeError.emptyPassphrase }
        let magicData = try magicBytes(magic)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let plaintext = try encoder.encode(value)

        let saltKey = SymmetricKey(size: .bits128)
        let salt = saltKey.withUnsafeBytes { Data($0) }
        let rounds = max(1, iterations)
        let roundsData = encoded(rounds)
        let authenticatedHeader = magicData + roundsData + salt
        let key = deriveKey(passphrase: passphrase, salt: salt, iterations: rounds)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedHeader)
        guard let combined = sealed.combined else {
            throw EncryptedArchiveEnvelopeError.invalidFormat
        }
        return authenticatedHeader + combined
    }

    static func open<T: Decodable>(
        _ type: T.Type,
        from encrypted: Data,
        passphrase: String,
        magic: String
    ) throws -> T {
        guard !passphrase.isEmpty else { throw EncryptedArchiveEnvelopeError.emptyPassphrase }
        let magicData = try magicBytes(magic)
        let headerLength = magicData.count + MemoryLayout<UInt32>.size + saltLength
        guard encrypted.count > headerLength,
              encrypted.prefix(magicData.count) == magicData else {
            throw EncryptedArchiveEnvelopeError.invalidFormat
        }
        let roundsRange = magicData.count ..< magicData.count + MemoryLayout<UInt32>.size
        let rounds = encrypted[roundsRange].reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        guard rounds > 0, rounds <= maximumAcceptedIterations else {
            throw EncryptedArchiveEnvelopeError.invalidFormat
        }
        let salt = Data(encrypted[roundsRange.upperBound ..< headerLength])
        let authenticatedHeader = Data(encrypted.prefix(headerLength))
        let key = deriveKey(passphrase: passphrase, salt: salt, iterations: rounds)
        do {
            let sealed = try AES.GCM.SealedBox(combined: Data(encrypted.dropFirst(headerLength)))
            let plaintext = try AES.GCM.open(sealed, using: key, authenticating: authenticatedHeader)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(T.self, from: plaintext)
        } catch {
            throw EncryptedArchiveEnvelopeError.decryptionFailed
        }
    }

    private static func magicBytes(_ magic: String) throws -> Data {
        let data = Data(magic.utf8)
        guard data.count == magicLength else { throw EncryptedArchiveEnvelopeError.invalidFormat }
        return data
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

/// 共享文件的读写抽象：默认走本地文件，测试可注入内存实现来制造并发写入时序。
protocol SharedFileStoring: Sendable {
    /// 文件不存在返回 nil；存在但读不出来应当抛错（例如 iCloud 还没下载完）。
    func read(at url: URL) throws -> Data?
    func write(_ data: Data, to url: URL) throws
}

struct SharedFileStore: SharedFileStoring {
    func read(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

enum SharedFileSyncError: LocalizedError, Equatable {
    /// 共享文件被其他设备持续改写：已把本机合并结果写到冲突副本。
    case conflictingWrites(conflictURL: URL)

    var errorDescription: String? {
        switch self {
        case let .conflictingWrites(conflictURL):
            return L("sync.error.conflict", conflictURL.lastPathComponent)
        }
    }
}

/// 能放进共享目录的文档：自己负责加解密与合并。
protocol SharedFileSyncDocument {
    /// 共享文件还不存在时使用的空文档。
    static var emptySharedDocument: Self { get }
    static func decryptShared(_ data: Data, passphrase: String) throws -> Self
    func encryptedShared(passphrase: String) throws -> Data
    func mergedShared(with remote: Self, now: Date) -> Self
}

/// 共享目录同步：读远端、合并、写回；写之前重新确认文件没被别的设备改过。
enum SharedFileSync {
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

    static func synchronize<Document: SharedFileSyncDocument>(
        local: Document,
        at url: URL,
        passphrase: String,
        store: any SharedFileStoring = SharedFileStore(),
        now: Date = Date()
    ) throws -> Document {
        var attempt = 0
        while true {
            attempt += 1
            let remoteData = try store.read(at: url)
            let remote = try remoteData
                .map { try Document.decryptShared($0, passphrase: passphrase) }
                ?? Document.emptySharedDocument
            let merged = local.mergedShared(with: remote, now: now)
            let encrypted = try merged.encryptedShared(passphrase: passphrase)

            // 写之前再确认一次文件没有被其他设备改过；改过就带着新内容重新合并，
            // 而不是把对方的更新直接盖掉。
            guard try store.read(at: url) == remoteData else {
                guard attempt < maximumAttempts else {
                    let conflictURL = conflictURL(for: url, now: now)
                    try store.write(encrypted, to: conflictURL)
                    throw SharedFileSyncError.conflictingWrites(conflictURL: conflictURL)
                }
                continue
            }

            try store.write(encrypted, to: url)
            return merged
        }
    }
}
