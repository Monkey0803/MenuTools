import Darwin
import Foundation

protocol SystemMemoryPurgeRunning: Sendable {
    /// 请求系统清理文件缓存；需要管理员授权。
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

/// 内存回收能力。
///
/// 拆成两条互不影响的路径，避免一键操作动辄弹出管理员授权：
/// - `relieveProcessMemory()` 只回收当前进程的 malloc 缓存，**不需要任何权限、永不弹授权框**；
/// - `purgeSystemCache()` 才请求系统清理文件缓存，**需要管理员授权**，会弹一次授权对话框。
///
/// macOS 不允许普通应用强制释放其他应用的匿名内存；系统 purge 只清理可安全回收的
/// 文件缓存，malloc relief 只处理当前进程的分配器缓存，都不会终止进程或删除用户数据。
protocol SystemMemoryReleasing: Sendable {
    func relieveProcessMemory() -> Int64
    func purgeSystemCache() -> Bool
}

struct DefaultSystemMemoryReleaser: SystemMemoryReleasing {
    private let purgeRunner: any SystemMemoryPurgeRunning

    init(purgeRunner: any SystemMemoryPurgeRunning = DefaultSystemMemoryPurgeRunner()) {
        self.purgeRunner = purgeRunner
    }

    func relieveProcessMemory() -> Int64 {
        Int64(malloc_zone_pressure_relief(nil, 0))
    }

    func purgeSystemCache() -> Bool {
        purgeRunner.purge()
    }
}
