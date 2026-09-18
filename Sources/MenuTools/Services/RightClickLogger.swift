import Foundation

/// 右键菜单操作日志记录器（持久化 + 控制台）
enum RightClickLogger {
    private static let logFile = logDirectory.appendingPathComponent("operations.log")
    private static let maxLogLines = 1000
    
    /// 是否启用日志记录
    @MainActor
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "rc_logger_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "rc_logger_enabled") }
    }
    
    static func enable() {
        Task { @MainActor in isEnabled = true }
    }
    
    static func disable() {
        Task { @MainActor in isEnabled = false }
    }
    
    /// 写入日志行（异步非阻塞）
    @MainActor
    static func log(_ message: String, level: String) {
        guard isEnabled else { return }
        
        Task.detached(priority: .utility) { [enabledState: isEnabled] in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(level): \(message)"
            
            // 追加到文件
            if let data = "\(line)\n".data(using: .utf8) {
                try? appendData(data, to: logFile)
            }
            
            // 限制文件大小
            truncateIfNeeded()
            
            // 控制台输出（开发环境）
            #if DEBUG
            print(line)
            #endif
        }
    }
    
    @MainActor
    static func error(_ message: String) {
        log(message, level: "ERROR")
    }
    
    @MainActor
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
    
    // MARK: - Private Helpers
    
    private static var logDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("com.monkey0803.MenuTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    
    private static func truncateIfNeeded() {
        guard let content = try? String(contentsOf: logFile, encoding: .utf8),
              !content.isEmpty else { return }
        
        let lines = content.components(separatedBy: "\n").filter({ !$0.isEmpty })
        if lines.count > maxLogLines {
            let truncated = Array(lines.suffix(maxLogLines)).joined(separator: "\n") + "\n"
            try? truncated.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Append Extension
private func appendData(_ data: Data, to url: URL) throws {
    guard let handle = try? FileHandle(forWritingTo: url) else {
        return
    }
    defer { try? handle.close() }
    handle.seekToEndOfFile()
    handle.write(data)
}
