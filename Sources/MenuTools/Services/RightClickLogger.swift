import Foundation

struct RightClickForwardedLog: Codable, Equatable, Sendable {
    let message: String
    let level: String

    static let allowedLevels: Set<String> = ["INFO", "ERROR", "PERF"]
    static let maximumMessageLength = 4_096

    var isValid: Bool {
        !message.isEmpty
            && message.utf8.count <= Self.maximumMessageLength
            && Self.allowedLevels.contains(level)
    }
}

/// 右键菜单操作日志记录器（持久化 + 控制台）。
///
/// 调用方既有主线程的设置页，也有 Finder 的 XPC 线程（扩展在 `menu(for:)` 里记性能），
/// 所以整组接口都是 nonisolated + 线程安全：开关来自共享配置，写入走串行 actor。
enum RightClickLogger {
    static let forwardedNotification = "com.qoder.menutools.rightclick.log"
    /// 日志文件位置；测试会先备份再独占使用，避免污染真实日志。
    static let logFile = logFileURL(inBaseDirectory: RightClickConfigStore.resolveBaseDirectory())
    private static let maxLogLines = 1000

    /// 日志与配置共用基础目录：App Group 可用时主 App 和 Finder 扩展读写同一文件；
    /// 不可用时 Finder 扩展通过分布式通知将受限事件转交给主 App 落盘。
    static var logDirectory: URL { logFile.deletingLastPathComponent() }

    static func logFileURL(inBaseDirectory base: URL) -> URL {
        base.appendingPathComponent("MenuTools", isDirectory: true)
            .appendingPathComponent("operations.log", isDirectory: false)
    }

    /// 开关状态；`nil` 表示本进程还没解析过。
    ///
    /// 扩展是沙盒进程，读不到主 App 的 `UserDefaults`，所以开关不能存在本地 defaults 里，
    /// 必须跟着共享配置（文件 + 分布式通知）走，两个进程才看到同一个值。
    private static let enabledState = RightClickLockedState<Bool?>(nil)

    /// 是否启用日志记录。首次访问时从本进程的配置缓存解析，之后随 `apply(_:)` 更新。
    static var isEnabled: Bool {
        if let resolved = enabledState.read() { return resolved }
        let resolved = RightClickConfigStore.load().loggerEnabled
        enabledState.mutate { $0 = resolved }
        return resolved
    }

    /// 配置变化（冷启动读取、收到广播或设置页保存）后同步开关。
    static func apply(_ config: RightClickConfig) {
        enabledState.mutate { $0 = config.loggerEnabled }
    }

    /// Finder 扩展无法在自签名构建中可靠写入主 App 的目录，因此把受限日志事件交给
    /// 已运行的主 App 落盘。主 App 也会再次检查当前开关，关闭日志后不会保留任何记录。
    static func forwardToHost(_ message: String, level: String = "PERF") {
        guard isEnabled, let payload = forwardedPayload(message: message, level: level) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(forwardedNotification), object: payload, deliverImmediately: true)
    }

    static func forwardedPayload(message: String, level: String) -> String? {
        let entry = RightClickForwardedLog(message: message, level: level)
        guard entry.isValid,
              let data = try? JSONEncoder().encode(entry) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeForwardedPayload(_ payload: String?) -> RightClickForwardedLog? {
        guard let payload,
              let data = payload.data(using: .utf8),
              let entry = try? JSONDecoder().decode(RightClickForwardedLog.self, from: data),
              entry.isValid else { return nil }
        return entry
    }

    static func receiveForwardedPayload(_ payload: String?) {
        guard let entry = decodeForwardedPayload(payload) else { return }
        log(entry.message, level: entry.level)
    }

    /// 写入日志行（异步非阻塞）
    static func log(_ message: String, level: String) {
        guard isEnabled else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(level): \(message)"

        // 交给串行写入器：多个日志调用并发进入时不会互相覆盖
        Task {
            await LogWriter.shared.append(line, to: logFile, keepingAtMost: maxLogLines)
        }

        // 控制台输出（开发环境）
        #if DEBUG
        print(line)
        #endif
    }
    
    static func error(_ message: String) {
        log(message, level: "ERROR")
    }
    
    static func performance(_ message: String) {
        log(message, level: "PERF")
    }
    
    /// 删除日志文件
    static func clear() {
        try? FileManager.default.removeItem(at: logFile)
    }
    
    /// 读取最近 N 条日志
    static func readRecent(count: Int) -> [String] {
        guard FileManager.default.fileExists(atPath: logFile.path) else { return [] }
        do {
            let text = try String(contentsOf: logFile, encoding: .utf8)
            let lines = text.split(separator: "\n").map(String.init)
            return Array(lines.suffix(count))
        } catch {
            return []
        }
    }
    
}

// MARK: - Serial Writer

/// 串行写入器：日志调用是并发进入的，由 actor 保证「建文件 + 追加 + 截断」不会互相覆盖。
private actor LogWriter {
    static let shared = LogWriter()

    func append(_ line: String, to url: URL, keepingAtMost maxLines: Int) {
        appendData(Data("\(line)\n".utf8), to: url)
        truncateIfNeeded(url, keepingAtMost: maxLines)
    }

    private func appendData(_ data: Data, to url: URL) {
        // FileHandle(forWritingTo:) 不会创建文件，首次写入必须先把文件建出来
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    private func truncateIfNeeded(_ url: URL, keepingAtMost maxLines: Int) {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              !content.isEmpty else { return }

        let lines = content.components(separatedBy: "\n").filter({ !$0.isEmpty })
        if lines.count > maxLines {
            let truncated = Array(lines.suffix(maxLines)).joined(separator: "\n") + "\n"
            try? truncated.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
