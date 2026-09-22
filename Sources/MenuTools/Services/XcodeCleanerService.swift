import Foundation

/// Xcode DerivedData 清理：容量统计 + 一键清空
enum XcodeCleanerService {

    enum CleanError: LocalizedError {
        case partialFailure(failed: Int, lastError: Error)

        var errorDescription: String? {
            switch self {
            case .partialFailure(let failed, let lastError):
                return L("error.cleanPartial", failed, lastError.localizedDescription)
            }
        }
    }

    nonisolated static var derivedDataURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    }

    /// 递归统计 DerivedData 占用的磁盘容量（字节）；目录不存在时返回 0
    nonisolated static func directorySize() -> Int64 {
        StorageAnalysisCalculator.directorySize(at: derivedDataURL)
    }

    /// 清空 DerivedData 目录内容（保留目录本身）；个别条目被占用时继续删其余项
    nonisolated static func clean() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: derivedDataURL.path) else { return }
        let items = try fileManager.contentsOfDirectory(at: derivedDataURL, includingPropertiesForKeys: nil)
        var failedCount = 0
        var lastError: Error?
        for item in items {
            do {
                try fileManager.removeItem(at: item)
            } catch {
                failedCount += 1
                lastError = error
            }
        }
        if let lastError {
            throw CleanError.partialFailure(failed: failedCount, lastError: lastError)
        }
    }

    /// 人类可读的容量文本
    nonisolated static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
