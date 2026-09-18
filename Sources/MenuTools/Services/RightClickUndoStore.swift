import Foundation

struct RightClickTransferProgress: Equatable, Sendable {
    var completedItems: Int
    var totalItems: Int
    var completedBytes: Int64
    var totalBytes: Int64
    var currentName: String
}

struct RightClickFileIdentity: Codable, Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
}

struct RightClickUndoRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case create, copy, move, rename }
    struct Entry: Codable, Equatable, Sendable {
        var source: String?
        var destination: String
        var destinationIdentity: RightClickFileIdentity
    }
    var kind: Kind
    var entries: [Entry]
}

/// 撤销历史：保留最近若干次文件操作，支持逐条回退。
///
/// 文件格式向后兼容旧版的单条记录；读取时逐条校验，非法记录不会进入历史。
enum RightClickUndoStore {
    static let maxDepth = 10

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MenuTools", isDirectory: true).appendingPathComponent("FinderRightClickUndo.json")
    }

    static func history(at url: URL = defaultURL) -> [RightClickUndoRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        let records: [RightClickUndoRecord]
        if let stored = try? decoder.decode(StoredHistory.self, from: data) {
            records = stored.records
        } else if let single = try? decoder.decode(RightClickUndoRecord.self, from: data) {
            records = [single]
        } else {
            return []
        }
        return Array(records.filter(isValid).suffix(maxDepth))
    }

    static func count(at url: URL = defaultURL) -> Int { history(at: url).count }

    /// 最近一次可撤销操作。
    static func load(at url: URL = defaultURL) -> RightClickUndoRecord? { history(at: url).last }

    static func push(_ record: RightClickUndoRecord, at url: URL = defaultURL) throws {
        guard isValid(record) else { throw RightClickFileError.undoTargetChanged }
        var records = history(at: url)
        records.append(record)
        if records.count > maxDepth { records.removeFirst(records.count - maxDepth) }
        try write(records, at: url)
    }

    /// 兼容旧调用：保存等于追加一条历史。
    static func save(_ record: RightClickUndoRecord, at url: URL = defaultURL) throws {
        try push(record, at: url)
    }

    static func removeLast(at url: URL = defaultURL) throws {
        var records = history(at: url)
        guard !records.isEmpty else { return }
        records.removeLast()
        if records.isEmpty {
            try clear(at: url)
        } else {
            try write(records, at: url)
        }
    }

    static func clear(at url: URL = defaultURL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private static func write(_ records: [RightClickUndoRecord], at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(StoredHistory(records: records)).write(to: url, options: [.atomic])
    }

    private struct StoredHistory: Codable {
        var records: [RightClickUndoRecord]
    }

    private static func isValid(_ record: RightClickUndoRecord) -> Bool {
        !record.entries.isEmpty && record.entries.count <= 1_000 && record.entries.allSatisfy { entry in
            guard isSafeAbsolutePath(entry.destination), entry.destinationIdentity.inode != 0 else { return false }
            if record.kind == .move || record.kind == .rename {
                guard let source = entry.source, isSafeAbsolutePath(source), source != entry.destination else {
                    return false
                }
            } else if let source = entry.source, !isSafeAbsolutePath(source) {
                return false
            }
            return true
        }
    }

    private static func isSafeAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.first == "" && components.dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
