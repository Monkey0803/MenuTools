import AppKit
import Foundation

/// 系统开关：隐藏文件 / 静音 / 程序坞自动隐藏 / 菜单栏自动隐藏
@MainActor
enum SystemToggleService {

    enum ToggleError: LocalizedError {
        case scriptFailure(String)

        var errorDescription: String? {
            switch self {
            case .scriptFailure(let message):
                return "操作失败：\(message)（如涉及“系统事件”，请在“系统设置 > 隐私与安全性 > 自动化”中允许 MenuTools）"
            }
        }
    }

    // MARK: - 隐藏文件（Finder）

    static var hiddenFilesShown: Bool {
        runProcess("/usr/bin/defaults", ["read", "com.apple.finder", "AppleShowAllFiles"]).output == "1"
    }

    /// 写入 Finder 偏好并重启 Finder（Finder 会自动重新启动）
    static func setHiddenFilesShown(_ shown: Bool) {
        runProcess("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", shown ? "true" : "false"])
        runProcess("/usr/bin/killall", ["Finder"])
    }

    // MARK: - 静音

    static var isMuted: Bool {
        let result = try? runAppleScript("output muted of (get volume settings)")
        return result?.booleanValue ?? false
    }

    static func setMuted(_ muted: Bool) throws {
        try runAppleScript("set volume output muted \(muted ? "true" : "false")")
    }

    // MARK: - 程序坞自动隐藏

    static var isDockHidden: Bool {
        runProcess("/usr/bin/defaults", ["read", "com.apple.dock", "autohide"]).output == "1"
    }

    static func setDockHidden(_ hidden: Bool) throws {
        try runAppleScript("""
        tell application "System Events" to set autohide of dock preferences to \(hidden ? "true" : "false")
        """)
    }

    // MARK: - 菜单栏自动隐藏

    static var isMenuBarHidden: Bool {
        runProcess("/usr/bin/defaults", ["read", "NSGlobalDomain", "_HIHideMenuBar"]).output == "1"
    }

    static func setMenuBarHidden(_ hidden: Bool) throws {
        try runAppleScript("""
        tell application "System Events" to set autohide menu bar of dock preferences to \(hidden ? "true" : "false")
        """)
    }

    // MARK: - Helpers

    @discardableResult
    private static func runAppleScript(_ source: String) throws -> NSAppleEventDescriptor {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw ToggleError.scriptFailure("脚本初始化失败")
        }
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "未知错误"
            throw ToggleError.scriptFailure(message)
        }
        return result
    }

    @discardableResult
    private static func runProcess(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, output)
    }
}
