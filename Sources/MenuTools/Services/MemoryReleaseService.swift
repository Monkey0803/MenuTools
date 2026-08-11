import Darwin
import Foundation

/// 一次内存释放操作的结果。
struct MemoryReleaseResult: Equatable, Sendable {
    /// 是否成功请求系统清理文件缓存。
    let systemCachePurged: Bool
    /// 当前进程 malloc 分配器实际归还的缓存字节数。
    let processReleasedBytes: Int64
}

protocol SystemMemoryPurgeRunning: Sendable {
    func purge() -> Bool
}

/// 通过 macOS 自带 purge 工具清理系统文件缓存。
///
/// purge 需要管理员权限，因此使用 osascript 的管理员授权对话框执行；用户取消授权
/// 时返回失败，不会尝试执行任意用户输入的命令。
struct DefaultSystemMemoryPurgeRunner: SystemMemoryPurgeRunning {
    private static let osascriptPath = "/usr/bin/osascript"
    private static let purgePath = "/usr/sbin/purge"

    func purge() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.osascriptPath)
        process.arguments = [
            "-e",
            "do shell script \"\(Self.purgePath)\" with administrator privileges"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// 释放当前进程可以安全回收的 malloc 缓存。
///
/// macOS 不允许普通应用强制释放其他应用的匿名内存；系统 purge 只清理可安全回收的
/// 文件缓存，malloc relief 只处理当前进程的分配器缓存，不会终止进程或删除用户数据。
protocol SystemMemoryReleasing: Sendable {
    func releaseMemory() -> MemoryReleaseResult
}

struct DefaultSystemMemoryReleaser: SystemMemoryReleasing {
    private let purgeRunner: any SystemMemoryPurgeRunning

    init(purgeRunner: any SystemMemoryPurgeRunning = DefaultSystemMemoryPurgeRunner()) {
        self.purgeRunner = purgeRunner
    }

    func releaseMemory() -> MemoryReleaseResult {
        let systemCachePurged = purgeRunner.purge()
        let processReleasedBytes = Int64(malloc_zone_pressure_relief(nil, 0))
        return MemoryReleaseResult(
            systemCachePurged: systemCachePurged,
            processReleasedBytes: processReleasedBytes
        )
    }
}
