import Foundation

/// 迁移残留（旧 JSON 与 `.migrated` 安全备份）的保留期清理。
///
/// 迁移到 SQLite 时会把旧 JSON 改名成 `.migrated` 作为安全网，但**没有任何代码删除它**：
/// 本机实测 `ClipboardHistory.json.migrated` 达 112 MB，网络流量的旧 JSON 还有 4.2 MB，
/// 而应用内既看不到这些文件、也没有清理入口。这里按保留期清掉，
/// 并且**只在替代库确实存在时才删**，避免把唯一的数据副本删掉。
enum MigrationResidueCleaner {
    /// 安全网保留期：迁移后 7 天内保留，之后视为过期残留。
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// 一个候选残留文件，以及它对应的替代库是否存在。
    struct Candidate: Equatable {
        var url: URL
        var modifiedAt: Date
        var replacementExists: Bool
    }

    /// 残留文件名与替代库文件名的对应关系。
    static let residuePairs: [(residue: String, replacement: String)] = [
        ("ClipboardHistory.json.migrated", "ClipboardHistory.sqlite3"),
        ("ClipboardHistory.json", "ClipboardHistory.sqlite3"),
        ("network-traffic-history.json", "network-traffic-history.sqlite3")
    ]

    /// 纯函数便于回归：挑出超过保留期、且替代库已存在的残留。
    static func expiredCandidates(
        _ candidates: [Candidate],
        now: Date,
        retention: TimeInterval = MigrationResidueCleaner.retention
    ) -> [URL] {
        candidates
            .filter { $0.replacementExists && now.timeIntervalSince($0.modifiedAt) >= retention }
            .map(\.url)
    }

    /// 在数据目录里清理过期残留，返回实际删除的文件。
    @discardableResult
    static func cleanExpired(
        in directory: URL,
        now: Date = Date(),
        retention: TimeInterval = MigrationResidueCleaner.retention,
        fileManager: FileManager = .default
    ) -> [URL] {
        var candidates: [Candidate] = []
        for pair in residuePairs {
            let residueURL = directory.appendingPathComponent(pair.residue)
            guard fileManager.fileExists(atPath: residueURL.path),
                  let attributes = try? fileManager.attributesOfItem(atPath: residueURL.path),
                  let modifiedAt = attributes[.modificationDate] as? Date else { continue }
            candidates.append(
                Candidate(
                    url: residueURL,
                    modifiedAt: modifiedAt,
                    replacementExists: fileManager.fileExists(
                        atPath: directory.appendingPathComponent(pair.replacement).path
                    )
                )
            )
        }
        return expiredCandidates(candidates, now: now, retention: retention)
            .filter { (try? fileManager.removeItem(at: $0)) != nil }
    }

    /// 应用数据目录：复用剪贴板持久化的路径解析，避免硬编码目录名。
    static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        ClipboardHistoryPersistence.defaultURL(fileManager: fileManager)?.deletingLastPathComponent()
    }

    /// 应用启动时调用：清理过期残留（失败静默，不影响启动）。
    static func cleanExpiredInDefaultDirectory(now: Date = Date()) {
        guard let directory = defaultDirectory() else { return }
        cleanExpired(in: directory, now: now)
    }
}
