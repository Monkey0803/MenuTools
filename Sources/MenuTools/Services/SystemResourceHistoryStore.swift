import Foundation
import SQLite3

/// 一条资源历史桶（按分钟聚合，多个采样取平均）。
struct SystemResourceHistoryBucket: Codable, Equatable, Sendable, Identifiable {
    let timestamp: Date
    let cpuUsage: Double
    let memoryUsedBytes: Int64
    let memoryTotalBytes: Int64
    let diskReadBytesPerSecond: Int64
    let diskWriteBytesPerSecond: Int64
    /// 参与平均的采样数。
    let sampleCount: Int

    var id: TimeInterval { timestamp.timeIntervalSince1970 }
    var memoryUsage: Double {
        memoryTotalBytes > 0 ? min(max(Double(memoryUsedBytes) / Double(memoryTotalBytes), 0), 1) : 0
    }
}

/// 历史桶的聚合与保留策略（纯函数，便于回归）。
enum SystemResourceHistoryAggregator {
    /// 资源历史保留 30 天，与网络流量历史一致。
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    /// 把一分钟内的多个采样合并成一条：CPU 与速率取平均，内存取最后一次读到的值。
    static func merging(
        existing: SystemResourceHistoryBucket?,
        snapshot: SystemResourceSnapshot,
        timestamp: Date
    ) -> SystemResourceHistoryBucket {
        guard let existing, existing.sampleCount > 0 else {
            return SystemResourceHistoryBucket(
                timestamp: timestamp,
                cpuUsage: snapshot.cpuUsage,
                memoryUsedBytes: snapshot.memoryUsedBytes,
                memoryTotalBytes: snapshot.memoryTotalBytes,
                diskReadBytesPerSecond: snapshot.diskReadBytesPerSecond,
                diskWriteBytesPerSecond: snapshot.diskWriteBytesPerSecond,
                sampleCount: 1
            )
        }

        let count = Double(existing.sampleCount)
        let nextCount = existing.sampleCount + 1
        let total = count + 1
        func average(_ previous: Double, _ current: Double) -> Double {
            (previous * count + current) / total
        }

        return SystemResourceHistoryBucket(
            timestamp: existing.timestamp,
            cpuUsage: average(existing.cpuUsage, snapshot.cpuUsage),
            memoryUsedBytes: snapshot.memoryUsedBytes,
            memoryTotalBytes: snapshot.memoryTotalBytes,
            diskReadBytesPerSecond: Int64(average(
                Double(existing.diskReadBytesPerSecond),
                Double(snapshot.diskReadBytesPerSecond)
            )),
            diskWriteBytesPerSecond: Int64(average(
                Double(existing.diskWriteBytesPerSecond),
                Double(snapshot.diskWriteBytesPerSecond)
            )),
            sampleCount: nextCount
        )
    }

    /// 丢弃超过保留期的桶。
    static func pruned(
        _ buckets: [SystemResourceHistoryBucket],
        now: Date,
        retention: TimeInterval = retentionInterval
    ) -> [SystemResourceHistoryBucket] {
        buckets.filter { now.timeIntervalSince($0.timestamp) < retention }
    }

    /// 把采样时间对齐到分钟。
    static func bucketTimestamp(for date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }
}

struct SystemResourceHistoryStorageUsage: Equatable, Sendable {
    let databaseBytes: Int64
    let walBytes: Int64
    let sharedMemoryBytes: Int64

    var totalBytes: Int64 { databaseBytes + walBytes + sharedMemoryBytes }
}

protocol SystemResourceHistoryStoring: AnyObject {
    func load(since: Date) -> [SystemResourceHistoryBucket]
    func save(_ buckets: [SystemResourceHistoryBucket])
    func clearAll()
    func storageUsage() -> SystemResourceHistoryStorageUsage
}

/// 资源历史的 SQLite 存储：沿用共享的存储策略与 PRAGMA。
final class SystemResourceHistoryStore: SystemResourceHistoryStoring {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("MenuTools", isDirectory: true)
            .appendingPathComponent("system-resource-history.sqlite3")
    }

    func load(since: Date) -> [SystemResourceHistoryBucket] {
        withDatabase(default: []) { database in
            createSchema(database)
            var statement: OpaquePointer?
            let sql = """
                SELECT bucket_timestamp, cpu_usage, memory_used, memory_total,
                       disk_read, disk_write, sample_count
                FROM resource_samples
                WHERE bucket_timestamp >= ?
                ORDER BY bucket_timestamp ASC
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                return []
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)

            var buckets: [SystemResourceHistoryBucket] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                buckets.append(SystemResourceHistoryBucket(
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    cpuUsage: sqlite3_column_double(statement, 1),
                    memoryUsedBytes: sqlite3_column_int64(statement, 2),
                    memoryTotalBytes: sqlite3_column_int64(statement, 3),
                    diskReadBytesPerSecond: sqlite3_column_int64(statement, 4),
                    diskWriteBytesPerSecond: sqlite3_column_int64(statement, 5),
                    sampleCount: Int(sqlite3_column_int64(statement, 6))
                ))
            }
            return buckets
        }
    }

    func save(_ buckets: [SystemResourceHistoryBucket]) {
        guard !buckets.isEmpty else { return }
        withDatabase(default: ()) { database in
            createSchema(database)
            SQLiteHistoryDatabase.execute(database, "BEGIN IMMEDIATE")
            var statement: OpaquePointer?
            let sql = """
                INSERT INTO resource_samples
                    (bucket_timestamp, cpu_usage, memory_used, memory_total, disk_read, disk_write, sample_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(bucket_timestamp) DO UPDATE SET
                    cpu_usage = excluded.cpu_usage,
                    memory_used = excluded.memory_used,
                    memory_total = excluded.memory_total,
                    disk_read = excluded.disk_read,
                    disk_write = excluded.disk_write,
                    sample_count = excluded.sample_count
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                SQLiteHistoryDatabase.execute(database, "ROLLBACK")
                return
            }
            defer { sqlite3_finalize(statement) }
            for bucket in buckets {
                sqlite3_reset(statement)
                sqlite3_bind_double(statement, 1, bucket.timestamp.timeIntervalSince1970)
                sqlite3_bind_double(statement, 2, bucket.cpuUsage)
                sqlite3_bind_int64(statement, 3, bucket.memoryUsedBytes)
                sqlite3_bind_int64(statement, 4, bucket.memoryTotalBytes)
                sqlite3_bind_int64(statement, 5, bucket.diskReadBytesPerSecond)
                sqlite3_bind_int64(statement, 6, bucket.diskWriteBytesPerSecond)
                sqlite3_bind_int64(statement, 7, Int64(bucket.sampleCount))
                sqlite3_step(statement)
            }
            SQLiteHistoryDatabase.execute(database, "COMMIT")
        }
    }

    func clearAll() {
        withDatabase(default: ()) { database in
            createSchema(database)
            SQLiteHistoryDatabase.execute(database, "DELETE FROM resource_samples")
        }
    }

    func storageUsage() -> SystemResourceHistoryStorageUsage {
        SystemResourceHistoryStorageUsage(
            databaseBytes: SQLiteHistoryDatabase.fileSize(at: fileURL),
            walBytes: SQLiteHistoryDatabase.fileSize(at: URL(fileURLWithPath: fileURL.path + "-wal")),
            sharedMemoryBytes: SQLiteHistoryDatabase.fileSize(at: URL(fileURLWithPath: fileURL.path + "-shm"))
        )
    }

    private func withDatabase<T>(default defaultValue: T, _ body: (OpaquePointer) -> T) -> T {
        SQLiteHistoryDatabase.withDatabase(at: fileURL, default: defaultValue, body)
    }

    private func createSchema(_ database: OpaquePointer) {
        SQLiteHistoryDatabase.execute(database, """
            CREATE TABLE IF NOT EXISTS resource_samples (
                bucket_timestamp REAL PRIMARY KEY,
                cpu_usage REAL NOT NULL,
                memory_used INTEGER NOT NULL,
                memory_total INTEGER NOT NULL,
                disk_read INTEGER NOT NULL,
                disk_write INTEGER NOT NULL,
                sample_count INTEGER NOT NULL
            ) WITHOUT ROWID
            """)
    }
}
