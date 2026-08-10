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

    var isSafeToClean: Bool { self != .downloads }

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
}

enum StorageAnalysisCalculator {
    static func snapshot() -> StorageAnalysisSnapshot {
        StorageAnalysisSnapshot(entries: StorageCategory.allCases.map { category in
            let exists = FileManager.default.fileExists(atPath: category.directoryURL.path)
            return StorageDirectoryInfo(
                category: category,
                bytes: exists ? directorySize(at: category.directoryURL) : 0,
                exists: exists
            )
        })
    }

    static func directorySize(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path),
              let enumerator = FileManager.default.enumerator(
                  at: url,
                  includingPropertiesForKeys: [.fileSizeKey],
                  options: [],
                  errorHandler: nil
              ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
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
        guard category.isSafeToClean else { throw StorageAnalysisError.unsafeCategory }
        try cleanContents(of: category.directoryURL)
    }
}

enum StorageAnalysisError: LocalizedError, Equatable {
    case unsafeCategory

    var errorDescription: String? { L("storage.cleanFailed") }
}

@MainActor
@Observable
final class StorageAnalysisService {
    private(set) var snapshot: StorageAnalysisSnapshot?
    private(set) var isLoading = false
    private(set) var cleaningCategory: StorageCategory?

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let result = await Task.detached(priority: .utility) {
                StorageAnalysisCalculator.snapshot()
            }.value
            snapshot = result
            isLoading = false
        }
    }

    func clean(_ category: StorageCategory) async throws {
        guard cleaningCategory == nil else { return }
        cleaningCategory = category
        defer { cleaningCategory = nil }
        try await Task.detached(priority: .userInitiated) {
            try StorageAnalysisCalculator.clean(category)
        }.value
        snapshot = await Task.detached(priority: .utility) {
            StorageAnalysisCalculator.snapshot()
        }.value
    }
}
