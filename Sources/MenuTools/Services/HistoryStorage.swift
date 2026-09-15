import Foundation
import SQLite3

/// 历史库的共享存储策略：库文件与 WAL 的容量上限。
///
/// 网络流量与系统资源两套历史都用同一份策略，避免各自定义上限后不一致。
enum HistoryStoragePolicy {
    static let maximumDatabaseBytes: Int64 = 64 * 1_024 * 1_024
    static let maximumWALBytes: Int64 = 8 * 1_024 * 1_024
    /// SQLite 默认页大小。
    static let defaultPageSize: Int64 = 4_096

    static func maximumPageCount(pageSize: Int64) -> Int64 {
        guard pageSize > 0 else { return 0 }
        return maximumDatabaseBytes / pageSize
    }
}

/// 打开 SQLite 历史库并应用统一的 PRAGMA（WAL、synchronous、容量上限）。
///
/// 只负责“打开 + 配置”，表结构由各模块自己创建；失败时统一走 defaultValue，
/// 不让采样路径因为磁盘问题抛错。
enum SQLiteHistoryDatabase {
    static func withDatabase<T>(
        at fileURL: URL,
        default defaultValue: T,
        _ body: (OpaquePointer) -> T
    ) -> T {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return defaultValue
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return defaultValue
        }
        defer { sqlite3_close(database) }
        applyStandardPragmas(database)
        return body(database)
    }

    /// WAL + 容量上限：追加写入不再每次重写整份历史，且库不会无限增长。
    static func applyStandardPragmas(_ database: OpaquePointer) {
        execute(database, "PRAGMA journal_mode=WAL")
        execute(database, "PRAGMA synchronous=NORMAL")
        execute(database, "PRAGMA foreign_keys=ON")
        execute(
            database,
            "PRAGMA max_page_count=\(HistoryStoragePolicy.maximumPageCount(pageSize: HistoryStoragePolicy.defaultPageSize))"
        )
        execute(database, "PRAGMA journal_size_limit=\(HistoryStoragePolicy.maximumWALBytes)")
    }

    static func execute(_ database: OpaquePointer, _ sql: String) {
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
