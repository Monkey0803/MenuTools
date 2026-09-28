import Foundation
import Testing
@testable import MenuTools

@Test("迁移残留只在超过保留期且替代库存在时才清理")
func migrationResidueExpiryRules() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let old = now.addingTimeInterval(-30 * 24 * 60 * 60)
    let recent = now.addingTimeInterval(-60 * 60)
    let backup = URL(fileURLWithPath: "/tmp/ClipboardHistory.json.migrated")
    let fresh = URL(fileURLWithPath: "/tmp/network-traffic-history.json")

    // 过期且替代库存在 → 清理
    #expect(
        MigrationResidueCleaner.expiredCandidates(
            [.init(url: backup, modifiedAt: old, replacementExists: true)],
            now: now
        ) == [backup]
    )
    // 未过期 → 保留（安全网还有用）
    #expect(
        MigrationResidueCleaner.expiredCandidates(
            [.init(url: fresh, modifiedAt: recent, replacementExists: true)],
            now: now
        ).isEmpty
    )
    // 替代库不存在 → 无论如何都保留，避免把唯一的数据副本删掉
    #expect(
        MigrationResidueCleaner.expiredCandidates(
            [.init(url: fresh, modifiedAt: old, replacementExists: false)],
            now: now
        ).isEmpty
    )
    // 刚好到期即视为过期
    #expect(
        MigrationResidueCleaner.expiredCandidates(
            [.init(
                url: backup,
                modifiedAt: now.addingTimeInterval(-MigrationResidueCleaner.retention),
                replacementExists: true
            )],
            now: now
        ) == [backup]
    )
}

@Test("在数据目录里清理过期迁移残留，未过期与无替代库的保留")
func migrationResidueCleanupRemovesOnlyExpiredFiles() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("MigrationResidueCleanerTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    func write(_ name: String, modifiedAt: Date) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("stale".utf8).write(to: url)
        try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let old = now.addingTimeInterval(-30 * 24 * 60 * 60)

    // 替代库存在：过期的备份会被清掉
    try Data("db".utf8).write(to: directory.appendingPathComponent("ClipboardHistory.sqlite3"))
    let expiredBackup = try write("ClipboardHistory.json.migrated", modifiedAt: old)
    // 未过期的备份保留
    let freshBackup = try write("ClipboardHistory.json", modifiedAt: now.addingTimeInterval(-60))
    // 替代库不存在：旧网络流量 JSON 保留
    let orphanLegacy = try write("network-traffic-history.json", modifiedAt: old)

    let removed = MigrationResidueCleaner.cleanExpired(in: directory, now: now)

    #expect(removed == [expiredBackup])
    #expect(!fileManager.fileExists(atPath: expiredBackup.path))
    #expect(fileManager.fileExists(atPath: freshBackup.path))
    #expect(fileManager.fileExists(atPath: orphanLegacy.path))
}
