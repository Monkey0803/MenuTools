import AppKit
import Foundation
import Observation

enum StorageCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case derivedData
    case xcodeArchives
    case iOSDeviceSupport
    case coreSimulator
    case caches
    case logs
    case downloads

    static let developerFiles: [StorageCategory] = [
        .derivedData,
        .xcodeArchives,
        .iOSDeviceSupport,
        .coreSimulator
    ]

    var id: String { rawValue }
    var titleKey: String { "storage.\(rawValue)" }
    var symbol: String {
        switch self {
        case .derivedData: return "hammer.fill"
        case .xcodeArchives: return "archivebox.fill"
        case .iOSDeviceSupport: return "iphone.gen3"
        case .coreSimulator: return "cpu"
        case .caches: return "shippingbox.fill"
        case .logs: return "doc.text.fill"
        case .downloads: return "arrow.down.circle.fill"
        }
    }

    /// 仅开放明确审核过、位于 Xcode 用户目录内的开发文件清理。
    /// CoreSimulator 可能包含模拟器 App 与数据，仅提供查看和建议。
    var isSafeToClean: Bool {
        switch self {
        case .derivedData, .xcodeArchives, .iOSDeviceSupport: return true
        case .coreSimulator, .caches, .logs, .downloads: return false
        }
    }

    var requiresManualReview: Bool { !isSafeToClean }
    var isDeveloperFile: Bool { Self.developerFiles.contains(self) }
    /// 支持安全清理的开发目录会展示其可独立选择的子项目。
    var supportsDetailedCleanup: Bool {
        switch self {
        case .derivedData, .xcodeArchives, .iOSDeviceSupport: true
        case .coreSimulator, .caches, .logs, .downloads: false
        }
    }

    var directoryURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .derivedData:
            return home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        case .xcodeArchives:
            return home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true)
        case .iOSDeviceSupport:
            return home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true)
        case .coreSimulator:
            return home.appendingPathComponent("Library/Developer/CoreSimulator", isDirectory: true)
        case .caches:
            return home.appendingPathComponent("Library/Caches", isDirectory: true)
        case .logs:
            return home.appendingPathComponent("Library/Logs", isDirectory: true)
        case .downloads:
            return home.appendingPathComponent("Downloads", isDirectory: true)
        }
    }
}

enum StorageDirectoryAccessIssue: Codable, Equatable, Sendable {
    case unreadable

    var localizedKey: String {
        switch self {
        case .unreadable: return "storage.unreadable"
        }
    }
}

struct StorageDirectoryInfo: Codable, Identifiable, Equatable, Sendable {
    let category: StorageCategory
    let bytes: Int64
    let exists: Bool
    let lastModified: Date?
    let accessIssue: StorageDirectoryAccessIssue?

    init(
        category: StorageCategory,
        bytes: Int64,
        exists: Bool,
        lastModified: Date? = nil,
        accessIssue: StorageDirectoryAccessIssue? = nil
    ) {
        self.category = category
        self.bytes = bytes
        self.exists = exists
        self.lastModified = lastModified
        self.accessIssue = accessIssue
    }

    var id: StorageCategory { category }
}

/// 开发目录中的一个可独立查看、选择和删除的项目。
/// `relativePath` 仅用于展示；删除始终使用 `directoryURL` 并再次做路径校验。
struct StorageDeveloperItem: Codable, Identifiable, Equatable, Sendable {
    let category: StorageCategory
    let title: String
    let relativePath: String
    let directoryURL: URL
    let bytes: Int64
    let lastModified: Date?
    let accessIssue: StorageDirectoryAccessIssue?

    var id: String { directoryURL.path }
}

struct StorageAnalysisSnapshot: Codable, Equatable, Sendable {
    let entries: [StorageDirectoryInfo]
    let volume: StorageVolumeOverview
    let developerItems: [StorageDeveloperItem]
    let simulatorItems: [CoreSimulatorStorageItem]
    let largeFiles: [StorageLargeFile]

    init(
        entries: [StorageDirectoryInfo],
        volume: StorageVolumeOverview,
        developerItems: [StorageDeveloperItem] = [],
        simulatorItems: [CoreSimulatorStorageItem] = [],
        largeFiles: [StorageLargeFile] = []
    ) {
        self.entries = entries
        self.volume = volume
        self.developerItems = developerItems
        self.simulatorItems = simulatorItems
        self.largeFiles = largeFiles
    }

    var sortedEntries: [StorageDirectoryInfo] {
        entries.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.category.rawValue < $1.category.rawValue
        }
    }

    func developerItems(for category: StorageCategory) -> [StorageDeveloperItem] {
        developerItems.filter { $0.category == category }
    }
}

struct StorageVolumeOverview: Codable, Equatable, Sendable {
    let totalBytes: Int64
    let availableBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}

/// 最近一次完成的扫描结果。只缓存文件元数据和统计值，不复制或读取用户文件内容。
struct StorageAnalysisCachedResult: Codable, Equatable, Sendable {
    let snapshot: StorageAnalysisSnapshot
    let scanDate: Date
}

/// 扫描缓存存入 Application Support，避免将大量目录项目写进 UserDefaults。
enum StorageAnalysisCacheStore {
    private static let maximumCacheBytes = 2 * 1024 * 1024

    static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("MenuTools", isDirectory: true)
            .appendingPathComponent("storage-analysis-cache.json", isDirectory: false)
    }

    static func load(at url: URL = defaultURL) -> StorageAnalysisCachedResult? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              attributes[.type] as? FileAttributeType == .typeRegular,
              size.int64Value <= Int64(maximumCacheBytes),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StorageAnalysisCachedResult.self, from: data)
    }

    static func save(_ result: StorageAnalysisCachedResult, at url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if url.deletingLastPathComponent().standardizedFileURL == defaultURL.deletingLastPathComponent().standardizedFileURL {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        }
        let data = try JSONEncoder().encode(result)
        guard data.count <= maximumCacheBytes else { return }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct StorageScanProgress: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int
    let currentCategory: StorageCategory?

    var fractionCompleted: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }
}

/// `Task.detached` 不会继承父任务的取消状态，因此用加锁令牌把取消请求传给文件枚举循环。
final class StorageScanCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum StorageRecommendationKind: String, Sendable {
    case staleDeveloperFiles
    case reviewDownloads

    var titleKey: String {
        switch self {
        case .staleDeveloperFiles: return "storage.recommendation.staleDeveloper"
        case .reviewDownloads: return "storage.recommendation.downloads"
        }
    }
}

struct StorageRecommendation: Identifiable, Equatable, Sendable {
    let kind: StorageRecommendationKind
    let category: StorageCategory
    let bytes: Int64
    let lastModified: Date

    var id: String { "\(kind.rawValue)-\(category.rawValue)" }
    var isReadOnly: Bool { true }
}

enum CoreSimulatorStorageKind: String, CaseIterable, Codable, Hashable, Sendable {
    case runtime, deviceData, appData, cache
    var titleKey: String { "storage.simulator.\(rawValue)" }
    var symbol: String {
        switch self {
        case .runtime: "iphone.gen3"
        case .deviceData: "externaldrive"
        case .appData: "app.fill"
        case .cache: "shippingbox.fill"
        }
    }
}

struct CoreSimulatorStorageItem: Codable, Identifiable, Equatable, Sendable {
    let kind: CoreSimulatorStorageKind
    let directoryURL: URL
    let bytes: Int64
    var id: CoreSimulatorStorageKind { kind }
}

enum StorageLargeFileMode: String, CaseIterable, Codable, Sendable {
    case largest, stale
    var titleKey: String { "storage.largeFiles.\(rawValue)" }
}

struct StorageLargeFile: Codable, Identifiable, Equatable, Sendable {
    let category: StorageCategory
    let mode: StorageLargeFileMode
    let fileURL: URL
    let bytes: Int64
    let date: Date
    var id: String { fileURL.path }
}

/// 每次扫描与清理都会推进代际；只有最新代际的异步结果可以更新界面。
struct StorageScanGeneration: Equatable, Sendable {
    private var current = 0

    mutating func begin() -> Int {
        current &+= 1
        return current
    }

    mutating func invalidate() {
        current &+= 1
    }

    func accepts(_ generation: Int) -> Bool {
        generation == current
    }
}

/// 用户确认清理前看到的可审计信息。
struct StorageCleanupPreview: Equatable, Sendable {
    let category: StorageCategory
    let reclaimableBytes: Int64
    let items: [StorageDeveloperItem]

    init(
        category: StorageCategory,
        reclaimableBytes: Int64,
        items: [StorageDeveloperItem] = []
    ) {
        self.category = category
        self.reclaimableBytes = reclaimableBytes
        self.items = items
    }

    var path: String { category.directoryURL.path }
    var directoryURL: URL { category.directoryURL }
}

private struct StorageDirectoryMeasurement: Sendable {
    let bytes: Int64
    let lastModified: Date?
    let accessIssue: StorageDirectoryAccessIssue?
}

enum StorageAnalysisCalculator {
    static func snapshot() -> StorageAnalysisSnapshot {
        scanSnapshot() ?? StorageAnalysisSnapshot(
            entries: [],
            volume: volumeOverview(at: FileManager.default.homeDirectoryForCurrentUser)
        )
    }

    /// 目录按顺序扫描，进度回调和取消检查均不依赖 AppKit，便于测试。
    static func scanSnapshot(
        progress: (@Sendable (StorageScanProgress) -> Void)? = nil,
        partial: (@Sendable (StorageAnalysisSnapshot) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> StorageAnalysisSnapshot? {
        let categories = StorageCategory.allCases
        let supplementalCategories: [StorageCategory] = [.caches, .downloads]
        let totalStages = categories.count + 1 + supplementalCategories.count
        var entries: [StorageDirectoryInfo] = []
        var detailedDeveloperItems: [StorageDeveloperItem] = []
        entries.reserveCapacity(categories.count)

        for (index, category) in categories.enumerated() {
            guard !isCancelled() else { return nil }
            progress?(StorageScanProgress(
                completedCount: index,
                totalCount: totalStages,
                currentCategory: category
            ))

            let url = category.directoryURL
            let exists = FileManager.default.fileExists(atPath: url.path)
            let measurement: StorageDirectoryMeasurement
            if exists, category.supportsDetailedCleanup {
                let existingEntries = entries
                let existingDeveloperItems = detailedDeveloperItems
                let volume = volumeOverview(at: FileManager.default.homeDirectoryForCurrentUser)
                guard let items = developerItems(
                    at: url,
                    category: category,
                    isCancelled: isCancelled,
                    onBatch: { items in
                        partial?(StorageAnalysisSnapshot(
                            entries: existingEntries + [StorageDirectoryInfo(
                                category: category,
                                bytes: items.reduce(0) { $0 + $1.bytes },
                                exists: true,
                                lastModified: items.compactMap(\.lastModified).max(),
                                accessIssue: items.contains(where: { $0.accessIssue != nil }) ? .unreadable : nil
                            )],
                            volume: volume,
                            developerItems: existingDeveloperItems + items
                        ))
                    }
                ) else {
                    return nil
                }
                detailedDeveloperItems.append(contentsOf: items)
                measurement = StorageDirectoryMeasurement(
                    bytes: items.reduce(0) { $0 + $1.bytes },
                    lastModified: items.compactMap(\.lastModified).max(),
                    accessIssue: items.contains(where: { $0.accessIssue != nil }) ? .unreadable : nil
                )
            } else {
                let existingEntries = entries
                let existingDeveloperItems = detailedDeveloperItems
                let volume = volumeOverview(at: FileManager.default.homeDirectoryForCurrentUser)
                measurement = exists
                    ? directoryMeasurement(
                        at: url,
                        isCancelled: isCancelled,
                        onBatch: { batch in
                            var partialEntries = existingEntries
                            partialEntries.append(StorageDirectoryInfo(
                                category: category,
                                bytes: batch.bytes,
                                exists: true,
                                lastModified: batch.lastModified,
                                accessIssue: batch.accessIssue
                            ))
                            partial?(StorageAnalysisSnapshot(
                                entries: partialEntries,
                                volume: volume,
                                developerItems: existingDeveloperItems
                            ))
                        }
                    )
                    : StorageDirectoryMeasurement(bytes: 0, lastModified: nil, accessIssue: nil)
            }
            guard !isCancelled() else { return nil }
            entries.append(StorageDirectoryInfo(
                category: category,
                bytes: measurement.bytes,
                exists: exists,
                lastModified: measurement.lastModified,
                accessIssue: measurement.accessIssue
            ))
            partial?(StorageAnalysisSnapshot(
                entries: entries,
                volume: volumeOverview(at: FileManager.default.homeDirectoryForCurrentUser),
                developerItems: detailedDeveloperItems
            ))
        }

        progress?(StorageScanProgress(
            completedCount: categories.count,
            totalCount: totalStages,
            currentCategory: .coreSimulator
        ))
        guard !isCancelled() else { return nil }
        let simulatorItems = simulatorBreakdown(
            at: StorageCategory.coreSimulator.directoryURL,
            isCancelled: isCancelled
        )
        guard !isCancelled() else { return nil }
        partial?(StorageAnalysisSnapshot(
            entries: entries,
            volume: volumeOverview(at: FileManager.default.homeDirectoryForCurrentUser),
            developerItems: detailedDeveloperItems,
            simulatorItems: simulatorItems
        ))

        var foundLargeFiles: [StorageLargeFile] = []
        for (index, category) in supplementalCategories.enumerated() {
            progress?(StorageScanProgress(
                completedCount: categories.count + 1 + index,
                totalCount: totalStages,
                currentCategory: category
            ))
            foundLargeFiles.append(contentsOf: largeFiles(
                at: category.directoryURL,
                category: category,
                isCancelled: isCancelled
            ))
            guard !isCancelled() else { return nil }
            partial?(StorageAnalysisSnapshot(
                entries: entries,
                volume: volumeOverview(at: FileManager.default.homeDirectoryForCurrentUser),
                developerItems: detailedDeveloperItems,
                simulatorItems: simulatorItems,
                largeFiles: foundLargeFiles
            ))
        }
        let visibleLargeFiles = StorageLargeFileMode.allCases.flatMap { mode in
            Array(foundLargeFiles
                .filter { $0.mode == mode }
                .sorted(by: Self.ordersLargeFiles)
                .prefix(20))
        }
        progress?(StorageScanProgress(
            completedCount: totalStages,
            totalCount: totalStages,
            currentCategory: nil
        ))
        return StorageAnalysisSnapshot(
            entries: entries,
            volume: volumeOverview(at: FileManager.default.homeDirectoryForCurrentUser),
            developerItems: detailedDeveloperItems,
            simulatorItems: simulatorItems,
            largeFiles: visibleLargeFiles
        )
    }

    /// 返回开发目录下可独立处理的项目。DerivedData 和 DeviceSupport 按直属目录细分；
    /// Archives 进一步细分到日期目录内的单个 `.xcarchive`。
    static func developerItems(
        at rootURL: URL,
        category: StorageCategory,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onBatch: (@Sendable ([StorageDeveloperItem]) -> Void)? = nil
    ) -> [StorageDeveloperItem]? {
        guard category.supportsDetailedCleanup else { return [] }
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        guard let candidates = developerItemCandidates(at: rootURL, category: category) else { return [] }

        var items: [StorageDeveloperItem] = []
        items.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard !isCancelled() else { return nil }
            guard !isSymbolicLink(candidate.url) else { continue }
            let completedItems = items
            let itemCategory = category
            let candidateURL = candidate.url
            let relativePath = candidate.relativePath
            let title = developerItemTitle(for: candidateURL, category: itemCategory)
            let measurement = directoryMeasurement(
                at: candidateURL,
                isCancelled: isCancelled,
                onBatch: { measurement in
                    let item = StorageDeveloperItem(
                        category: itemCategory,
                        title: title,
                        relativePath: relativePath,
                        directoryURL: candidateURL,
                        bytes: measurement.bytes,
                        lastModified: measurement.lastModified,
                        accessIssue: measurement.accessIssue
                    )
                    onBatch?(completedItems + [item])
                }
            )
            guard !isCancelled() else { return nil }
            items.append(StorageDeveloperItem(
                category: itemCategory,
                title: title,
                relativePath: relativePath,
                directoryURL: candidateURL,
                bytes: measurement.bytes,
                lastModified: measurement.lastModified,
                accessIssue: measurement.accessIssue
            ))
            onBatch?(items)
        }
        return items.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    static func volumeOverview(at url: URL) -> StorageVolumeOverview {
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ])
        let totalCapacity: Int = values?.volumeTotalCapacity ?? 0
        let fallbackAvailable: Int? = values?.volumeAvailableCapacity
        let total = Int64(totalCapacity)
        let available = Int64(fallbackAvailable ?? 0)
        return StorageVolumeOverview(totalBytes: total, availableBytes: min(max(0, available), total))
    }

    /// 统计实际占用的磁盘块；与删除开发目录后可释放的容量保持一致。
    static func directorySize(
        at url: URL,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> Int64 {
        directoryMeasurement(at: url, isCancelled: isCancelled).bytes
    }

    static func recommendations(
        for entries: [StorageDirectoryInfo],
        now: Date = .now,
        staleAfter: TimeInterval = 30 * 24 * 60 * 60
    ) -> [StorageRecommendation] {
        let cutoff = now.addingTimeInterval(-staleAfter)
        return entries.compactMap { entry in
            guard entry.bytes > 0,
                  let lastModified = entry.lastModified,
                  lastModified < cutoff else { return nil }
            let kind: StorageRecommendationKind?
            if entry.category.isDeveloperFile {
                kind = .staleDeveloperFiles
            } else if entry.category == .downloads {
                kind = .reviewDownloads
            } else {
                kind = nil
            }
            return kind.map {
                StorageRecommendation(
                    kind: $0,
                    category: entry.category,
                    bytes: entry.bytes,
                    lastModified: lastModified
                )
            }
        }
        .sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.category.rawValue < $1.category.rawValue
        }
    }

    static func cleanContents(of url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        for item in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: item)
        }
    }

    /// 仅删除用户选中的开发项目；每个项目在删除前再次确认仍位于对应的允许根目录中。
    static func clean(_ items: [StorageDeveloperItem]) throws {
        guard let category = items.first?.category,
              !items.isEmpty,
              category.supportsDetailedCleanup,
              items.allSatisfy({ $0.category == category }) else {
            throw StorageAnalysisError.unsafeCategory
        }

        let root = category.directoryURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        try clean(items, allowedRoot: root, homeDirectory: home)
    }

    /// 删除细分项目的可测试边界；生产调用固定传入分类对应的允许根目录。
    static func clean(
        _ items: [StorageDeveloperItem],
        allowedRoot: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        guard let category = items.first?.category,
              !items.isEmpty,
              category.supportsDetailedCleanup,
              items.allSatisfy({ $0.category == category }) else {
            throw StorageAnalysisError.unsafeCategory
        }
        for item in items {
            try StorageCleanupPathPolicy.validateItem(
                item.directoryURL,
                allowedRoot: allowedRoot,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            try fileManager.removeItem(at: item.directoryURL)
        }
    }

    private struct DeveloperItemCandidate {
        let url: URL
        let relativePath: String
    }

    private static func developerItemCandidates(
        at rootURL: URL,
        category: StorageCategory
    ) -> [DeveloperItemCandidate]? {
        guard let directChildren = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return nil }

        if category != .xcodeArchives {
            return directChildren.map {
                DeveloperItemCandidate(url: $0, relativePath: $0.lastPathComponent)
            }
        }

        var candidates: [DeveloperItemCandidate] = []
        for child in directChildren {
            if child.pathExtension == "xcarchive" || !isDirectory(child) {
                candidates.append(.init(url: child, relativePath: child.lastPathComponent))
                continue
            }
            guard let archives = try? FileManager.default.contentsOfDirectory(
                at: child,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ), !archives.isEmpty else {
                candidates.append(.init(url: child, relativePath: child.lastPathComponent))
                continue
            }
            candidates.append(contentsOf: archives.map {
                .init(url: $0, relativePath: "\(child.lastPathComponent)/\($0.lastPathComponent)")
            })
        }
        return candidates
    }

    private static func developerItemTitle(for url: URL, category: StorageCategory) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard category == .derivedData else { return name }
        let components = name.split(separator: "-", omittingEmptySubsequences: false)
        guard let suffix = components.last,
              suffix.count >= 12,
              suffix.allSatisfy({ $0.isLetter || $0.isNumber }),
              components.count > 1 else { return name }
        return components.dropLast().joined(separator: "-")
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func simulatorBreakdown(
        at root: URL,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> [CoreSimulatorStorageItem] {
        let userRuntime = root.appendingPathComponent("Profiles/Runtimes", isDirectory: true)
        let systemRuntime = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/Runtimes", isDirectory: true)
        let runtime = FileManager.default.fileExists(atPath: systemRuntime.path) ? systemRuntime : userRuntime
        let devices = root.appendingPathComponent("Devices", isDirectory: true)
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        let appPaths = (try? FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)) ?? []
        var appBytes: Int64 = 0
        for device in appPaths {
            guard !isCancelled() else { return [] }
            appBytes += directorySize(
                at: device.appendingPathComponent("data/Containers/Data/Application", isDirectory: true),
                isCancelled: isCancelled
            )
        }
        guard !isCancelled() else { return [] }
        let deviceTotal = directorySize(at: devices, isCancelled: isCancelled)
        return [
            .init(kind: .runtime, directoryURL: runtime, bytes: directorySize(at: runtime, isCancelled: isCancelled)),
            .init(kind: .deviceData, directoryURL: devices, bytes: max(0, deviceTotal - appBytes)),
            .init(kind: .appData, directoryURL: devices, bytes: appBytes),
            .init(kind: .cache, directoryURL: caches, bytes: directorySize(at: caches, isCancelled: isCancelled))
        ]
    }

    /// 单次遍历一个目录，同时保留两种视图各自最大的前 N 项，避免将全部文件读入内存。
    static func largeFiles(
        at root: URL,
        category: StorageCategory,
        now: Date = .now,
        staleAfter: TimeInterval = 30 * 24 * 60 * 60,
        limit: Int = 20,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> [StorageLargeFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .contentAccessDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let cutoff = now.addingTimeInterval(-staleAfter)
        var largest: [StorageLargeFile] = []
        var stale: [StorageLargeFile] = []
        for case let url as URL in enumerator {
            guard !isCancelled() else { return [] }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .contentAccessDateKey]),
                  values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            guard bytes > 0 else { continue }
            let date = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            insertLargeFile(.init(category: category, mode: .largest, fileURL: url, bytes: bytes, date: date), into: &largest, limit: limit)
            if date < cutoff {
                insertLargeFile(.init(category: category, mode: .stale, fileURL: url, bytes: bytes, date: date), into: &stale, limit: limit)
            }
        }
        return largest + stale
    }

    static func largeFiles(
        at root: URL,
        category: StorageCategory,
        mode: StorageLargeFileMode,
        now: Date = .now,
        staleAfter: TimeInterval = 30 * 24 * 60 * 60,
        limit: Int = 20,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> [StorageLargeFile] {
        largeFiles(
            at: root,
            category: category,
            now: now,
            staleAfter: staleAfter,
            limit: limit,
            isCancelled: isCancelled
        )
        .filter { $0.mode == mode }
    }

    private static func insertLargeFile(_ item: StorageLargeFile, into items: inout [StorageLargeFile], limit: Int) {
        let index = items.firstIndex { ordersLargeFiles(item, $0) } ?? items.endIndex
        items.insert(item, at: index)
        if items.count > limit { items.removeLast() }
    }

    private static func ordersLargeFiles(_ lhs: StorageLargeFile, _ rhs: StorageLargeFile) -> Bool {
        if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
        return lhs.fileURL.path < rhs.fileURL.path
    }

    private static func directoryMeasurement(
        at url: URL,
        isCancelled: @escaping @Sendable () -> Bool,
        onBatch: (@Sendable (StorageDirectoryMeasurement) -> Void)? = nil
    ) -> StorageDirectoryMeasurement {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return StorageDirectoryMeasurement(bytes: 0, lastModified: nil, accessIssue: nil)
        }
        let requestedKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let rootValues = try? url.resourceValues(forKeys: [.isReadableKey, .contentModificationDateKey])
        guard rootValues?.isReadable != false else {
            return StorageDirectoryMeasurement(bytes: 0, lastModified: nil, accessIssue: .unreadable)
        }

        var didEncounterReadError = false
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(requestedKeys),
            options: [],
            errorHandler: { _, _ in
                didEncounterReadError = true
                return true
            }
        ) else {
            return StorageDirectoryMeasurement(bytes: 0, lastModified: nil, accessIssue: .unreadable)
        }

        var total: Int64 = 0
        var lastModified = rootValues?.contentModificationDate
        var scannedItemCount = 0
        for case let fileURL as URL in enumerator {
            if isCancelled() {
                return StorageDirectoryMeasurement(bytes: total, lastModified: lastModified, accessIssue: nil)
            }
            let values = try? fileURL.resourceValues(forKeys: requestedKeys)
            if values?.isRegularFile == true {
                total += Int64(values?.fileAllocatedSize ?? values?.fileSize ?? 0)
            }
            if let date = values?.contentModificationDate,
               lastModified == nil || date > lastModified! {
                lastModified = date
            }
            scannedItemCount += 1
            if scannedItemCount.isMultiple(of: 500) {
                onBatch?(StorageDirectoryMeasurement(
                    bytes: total,
                    lastModified: lastModified,
                    accessIssue: didEncounterReadError ? .unreadable : nil
                ))
            }
        }
        return StorageDirectoryMeasurement(
            bytes: total,
            lastModified: lastModified,
            accessIssue: didEncounterReadError ? .unreadable : nil
        )
    }
}

enum StorageCleanupPathPolicy {
    static func validate(category: StorageCategory) throws {
        guard category.isSafeToClean else { throw StorageAnalysisError.unsafeCategory }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let allowedRoot = category.directoryURL
        try validate(allowedRoot, allowedRoot: allowedRoot, homeDirectory: home)
    }

    /// 防止清理入口被重定向到 Home 之外或符号链接目标。
    static func validate(
        _ url: URL,
        allowedRoot: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try validate(
            url,
            allowedRoot: allowedRoot,
            homeDirectory: homeDirectory,
            requiresExactRoot: true,
            fileManager: fileManager
        )
    }

    /// 校验一个待删除的细分项目。项目必须是允许根目录的后代，不能等于根目录本身。
    static func validateItem(
        _ url: URL,
        allowedRoot: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try validate(
            url,
            allowedRoot: allowedRoot,
            homeDirectory: homeDirectory,
            requiresExactRoot: false,
            fileManager: fileManager
        )
    }

    private static func validate(
        _ url: URL,
        allowedRoot: URL,
        homeDirectory: URL,
        requiresExactRoot: Bool,
        fileManager: FileManager
    ) throws {
        let target = url.standardizedFileURL
        let root = allowedRoot.standardizedFileURL
        let home = homeDirectory.standardizedFileURL
        let isAllowedTarget = requiresExactRoot
            ? target.path == root.path
            : target.path != root.path && target.path.hasPrefix(root.path + "/")
        guard isAllowedTarget,
              target.path == home.path || target.path.hasPrefix(home.path + "/") else {
            throw StorageAnalysisError.unsafePath
        }

        let targetComponents = target.pathComponents
        let homeComponents = home.pathComponents
        guard targetComponents.starts(with: homeComponents) else {
            throw StorageAnalysisError.unsafePath
        }

        // Home 自身由系统提供；只检查其下的组件，避免把 `/var` 这类系统别名
        // 误判为用户清理路径中的符号链接。
        var componentURL = home
        for component in targetComponents.dropFirst(homeComponents.count) {
            componentURL.appendPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: componentURL.path) else { continue }
            let values = try componentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw StorageAnalysisError.unsafePath
            }
        }
    }
}

enum StorageCleanupPolicy {
    static func canClean(_ category: StorageCategory, isXcodeRunning: Bool) -> Bool {
        category.isSafeToClean && !isXcodeRunning
    }
}

enum StorageAnalysisError: LocalizedError, Equatable {
    case unsafeCategory
    case unsafePath
    case xcodeRunning

    var errorDescription: String? {
        switch self {
        case .unsafeCategory: L("storage.cleanFailed")
        case .unsafePath: L("storage.unsafePath")
        case .xcodeRunning: L("storage.xcodeRunning")
        }
    }
}

@MainActor
@Observable
final class StorageAnalysisService {
    static let shared = StorageAnalysisService()
    private typealias ScanLoader = @Sendable (
        @escaping @Sendable (StorageScanProgress) -> Void,
        @escaping @Sendable (StorageAnalysisSnapshot) -> Void,
        @escaping @Sendable () -> Bool
    ) -> StorageAnalysisSnapshot?
    private typealias CacheSaver = @Sendable (StorageAnalysisCachedResult) -> Void

    private let scanLoader: ScanLoader
    private let cacheSaver: CacheSaver
    private(set) var snapshot: StorageAnalysisSnapshot?
    private(set) var isLoading = false
    private(set) var scanProgress: StorageScanProgress?
    private(set) var lastScanWasCancelled = false
    private(set) var lastScanDate: Date?
    private(set) var cleaningCategory: StorageCategory?
    private var scanGeneration = StorageScanGeneration()
    private var refreshTask: Task<Void, Never>?
    private var scanCancellationToken: StorageScanCancellationToken?
    /// 完整快照刷新期间保留旧结果；首次扫描才以部分结果逐步填充界面。
    private var snapshotIsPartial = false

    convenience init() {
        self.init(
            cachedResult: StorageAnalysisCacheStore.load(),
            scanLoader: { progress, partial, isCancelled in
                StorageAnalysisCalculator.scanSnapshot(
                    progress: progress,
                    partial: partial,
                    isCancelled: isCancelled
                )
            },
            cacheSaver: { result in try? StorageAnalysisCacheStore.save(result) }
        )
    }

    convenience init(snapshotLoader: @escaping @Sendable () -> StorageAnalysisSnapshot) {
        self.init(cachedResult: nil, snapshotLoader: snapshotLoader)
    }

    convenience init(
        cachedResult: StorageAnalysisCachedResult?,
        snapshotLoader: @escaping @Sendable () -> StorageAnalysisSnapshot
    ) {
        self.init(cachedResult: cachedResult, scanLoader: { _, _, isCancelled in
            guard !isCancelled() else { return nil }
            return snapshotLoader()
        }, cacheSaver: { _ in })
    }

    init(
        cachedResult: StorageAnalysisCachedResult? = nil,
        progressiveSnapshotLoader: @escaping @Sendable (
            @escaping @Sendable (StorageScanProgress) -> Void,
            @escaping @Sendable (StorageAnalysisSnapshot) -> Void,
            @escaping @Sendable () -> Bool
        ) -> StorageAnalysisSnapshot?
    ) {
        scanLoader = progressiveSnapshotLoader
        cacheSaver = { _ in }
        snapshot = cachedResult?.snapshot
        lastScanDate = cachedResult?.scanDate
    }

    private init(
        cachedResult: StorageAnalysisCachedResult?,
        scanLoader: @escaping ScanLoader,
        cacheSaver: @escaping CacheSaver
    ) {
        self.scanLoader = scanLoader
        self.cacheSaver = cacheSaver
        snapshot = cachedResult?.snapshot
        lastScanDate = cachedResult?.scanDate
    }

    var recommendations: [StorageRecommendation] {
        guard let snapshot else { return [] }
        return StorageAnalysisCalculator.recommendations(for: snapshot.entries)
    }

    func refresh() {
        guard cleaningCategory == nil, !isLoading else { return }
        let generation = scanGeneration.begin()
        refreshTask?.cancel()
        scanCancellationToken?.cancel()
        let cancellationToken = StorageScanCancellationToken()
        scanCancellationToken = cancellationToken
        isLoading = true
        lastScanWasCancelled = false
        scanProgress = StorageScanProgress(
            completedCount: 0,
            totalCount: StorageCategory.allCases.count,
            currentCategory: nil
        )
        let scanLoader = scanLoader
        let reportProgress: @Sendable (StorageScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.scanGeneration.accepts(generation) else { return }
                self.scanProgress = progress
            }
        }
        let reportPartial: @Sendable (StorageAnalysisSnapshot) -> Void = { [weak self] partial in
            Task { @MainActor [weak self] in
                guard let self, self.scanGeneration.accepts(generation) else { return }
                guard self.snapshot == nil || self.snapshotIsPartial else { return }
                self.snapshot = partial
                self.snapshotIsPartial = true
            }
        }
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                scanLoader(reportProgress, reportPartial, { cancellationToken.isCancelled || Task.isCancelled })
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.scanGeneration.accepts(generation),
                  let result else { return }
            self.snapshot = result
            self.snapshotIsPartial = false
            self.lastScanDate = .now
            let cachedResult = StorageAnalysisCachedResult(snapshot: result, scanDate: self.lastScanDate ?? .now)
            let cacheSaver = self.cacheSaver
            cacheSaver(cachedResult)
            self.isLoading = false
            self.scanProgress = nil
            if self.scanCancellationToken === cancellationToken {
                self.scanCancellationToken = nil
            }
            self.refreshTask = nil
        }
    }

    func cancelRefresh() {
        invalidateRefresh(markCancelled: true)
    }

    func clean(_ items: [StorageDeveloperItem]) async throws {
        guard let category = items.first?.category,
              !items.isEmpty,
              items.allSatisfy({ $0.category == category }),
              category.supportsDetailedCleanup else {
            throw StorageAnalysisError.unsafeCategory
        }
        let xcodeIsRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.dt.Xcode"
        }
        guard StorageCleanupPolicy.canClean(category, isXcodeRunning: xcodeIsRunning) else {
            throw xcodeIsRunning ? StorageAnalysisError.xcodeRunning : StorageAnalysisError.unsafeCategory
        }
        invalidateRefresh()
        cleaningCategory = category
        do {
            try await Task.detached(priority: .userInitiated) {
                try StorageAnalysisCalculator.clean(items)
            }.value
            cleaningCategory = nil
            refresh()
        } catch {
            cleaningCategory = nil
            refresh()
            throw error
        }
    }

    func cleanupPreview(for items: [StorageDeveloperItem]) -> StorageCleanupPreview? {
        guard let category = items.first?.category,
              category.supportsDetailedCleanup,
              items.allSatisfy({ $0.category == category }) else { return nil }
        return StorageCleanupPreview(
            category: category,
            reclaimableBytes: items.reduce(0) { $0 + $1.bytes },
            items: items
        )
    }

    private func invalidateRefresh(markCancelled: Bool = false) {
        scanGeneration.invalidate()
        refreshTask?.cancel()
        refreshTask = nil
        scanCancellationToken?.cancel()
        scanCancellationToken = nil
        if snapshotIsPartial {
            snapshot = nil
            snapshotIsPartial = false
        }
        isLoading = false
        scanProgress = nil
        lastScanWasCancelled = markCancelled
    }
}
