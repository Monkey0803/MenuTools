import AppKit
import Foundation
import Observation

enum StorageCategory: String, CaseIterable, Identifiable, Sendable {
    case derivedData
    case caches
    case logs
    case downloads

    var id: String { rawValue }
    var titleKey: String { "storage.\(rawValue)" }
    var symbol: String {
        switch self {
        case .derivedData: return "hammer.fill"
        case .caches: return "shippingbox.fill"
        case .logs: return "doc.text.fill"
        case .downloads: return "arrow.down.circle.fill"
        }
    }

    /// 只允许清理经过明确审核的开发缓存。
    ///
    /// `Library/Caches` 与 `Library/Logs` 是多个 App 共用的位置，下载目录还可能包含用户文件，
    /// 因此它们仅用于分析展示，不能由 MenuTools 批量删除。
    var isSafeToClean: Bool { self == .derivedData }

    var directoryURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .derivedData: return home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        case .caches: return home.appendingPathComponent("Library/Caches", isDirectory: true)
        case .logs: return home.appendingPathComponent("Library/Logs", isDirectory: true)
        case .downloads: return home.appendingPathComponent("Downloads", isDirectory: true)
        }
    }
}

struct StorageDirectoryInfo: Identifiable, Equatable, Sendable {
    let category: StorageCategory
    let bytes: Int64
    let exists: Bool

    var id: StorageCategory { category }
}

struct StorageAnalysisSnapshot: Equatable, Sendable {
    let entries: [StorageDirectoryInfo]
    let volume: StorageVolumeOverview
}

struct StorageVolumeOverview: Equatable, Sendable {
    let totalBytes: Int64
    let availableBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
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

    var path: String { category.directoryURL.path }
    var directoryURL: URL { category.directoryURL }
}

enum StorageAnalysisCalculator {
    static func snapshot() -> StorageAnalysisSnapshot {
        StorageAnalysisSnapshot(
            entries: StorageCategory.allCases.map { category in
                let exists = FileManager.default.fileExists(atPath: category.directoryURL.path)
                return StorageDirectoryInfo(
                    category: category,
                    bytes: exists ? directorySize(at: category.directoryURL) : 0,
                    exists: exists
                )
            },
            volume: volumeOverview(at: FileManager.default.homeDirectoryForCurrentUser)
        )
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

    /// 统计实际占用的磁盘块；与删除 DerivedData 后可释放的容量保持一致。
    static func directorySize(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path),
              let enumerator = FileManager.default.enumerator(
                  at: url,
                  includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey],
                  options: [],
                  errorHandler: nil
              ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileAllocatedSize ?? values?.fileSize ?? 0)
            }
        }
        return total
    }

    static func cleanContents(of url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        for item in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: item)
        }
    }

    static func clean(_ category: StorageCategory) throws {
        try StorageCleanupPathPolicy.validate(category: category)
        try cleanContents(of: category.directoryURL)
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
        let target = url.standardizedFileURL
        let root = allowedRoot.standardizedFileURL
        let home = homeDirectory.standardizedFileURL
        guard target.path == root.path,
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
        category.isSafeToClean && !(category == .derivedData && isXcodeRunning)
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
    private let snapshotLoader: @Sendable () -> StorageAnalysisSnapshot
    private(set) var snapshot: StorageAnalysisSnapshot?
    private(set) var isLoading = false
    private(set) var cleaningCategory: StorageCategory?
    private var scanGeneration = StorageScanGeneration()
    private var refreshTask: Task<Void, Never>?

    init(
        snapshotLoader: @escaping @Sendable () -> StorageAnalysisSnapshot = StorageAnalysisCalculator.snapshot
    ) {
        self.snapshotLoader = snapshotLoader
    }

    func refresh() {
        guard cleaningCategory == nil else { return }
        let generation = scanGeneration.begin()
        refreshTask?.cancel()
        isLoading = true
        let snapshotLoader = snapshotLoader
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                snapshotLoader()
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.scanGeneration.accepts(generation) else { return }
            self.snapshot = result
            self.isLoading = false
            self.refreshTask = nil
        }
    }

    func clean(_ category: StorageCategory) async throws {
        guard cleaningCategory == nil else { return }
        let xcodeIsRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.dt.Xcode"
        }
        guard StorageCleanupPolicy.canClean(category, isXcodeRunning: xcodeIsRunning) else {
            throw category == .derivedData && xcodeIsRunning
                ? StorageAnalysisError.xcodeRunning
                : StorageAnalysisError.unsafeCategory
        }
        invalidateRefresh()
        cleaningCategory = category
        do {
            try await Task.detached(priority: .userInitiated) {
                try StorageAnalysisCalculator.clean(category)
            }.value
            cleaningCategory = nil
            refresh()
        } catch {
            cleaningCategory = nil
            refresh()
            throw error
        }
    }

    func cleanupPreview(for entry: StorageDirectoryInfo) -> StorageCleanupPreview? {
        guard entry.category.isSafeToClean, entry.bytes > 0 else { return nil }
        return StorageCleanupPreview(category: entry.category, reclaimableBytes: entry.bytes)
    }

    private func invalidateRefresh() {
        scanGeneration.invalidate()
        refreshTask?.cancel()
        refreshTask = nil
        isLoading = false
    }
}
