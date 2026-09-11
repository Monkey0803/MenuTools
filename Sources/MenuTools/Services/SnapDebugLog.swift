import Foundation

/// 拖拽吸附的诊断日志。
///
/// 只有存在 `/tmp/menutools-snap-debug` 标记文件时才写日志，用来排查「拖动窗口时没有落点预览」
/// 这类只能靠真实拖拽复现的问题：
///
///     touch /tmp/menutools-snap-debug     # 打开
///     rm /tmp/menutools-snap-debug /tmp/menutools-snap.log   # 关闭并清理
///
/// 标记不存在时每次调用只做一次文件存在判断，开销可以忽略。
enum SnapDebugLog {
    private static let markerPath = "/tmp/menutools-snap-debug"
    private static let logPath = "/tmp/menutools-snap.log"

    /// 每个进程只判断一次，避免拖拽过程中反复访问文件系统。
    private static let isEnabled = FileManager.default.fileExists(atPath: markerPath)

    static func log(_ message: String) {
        guard isEnabled else { return }
        let line = "\(timestamp()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
