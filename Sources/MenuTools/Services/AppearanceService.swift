import AppKit
import Foundation

/// 系统外观（深色 / 浅色）读取与切换
enum AppearanceService {

    enum AppearanceError: LocalizedError {
        case scriptFailure(String)

        var errorDescription: String? {
            switch self {
            case .scriptFailure(let message):
                return L("error.appearance", message)
            }
        }
    }

    /// 当前系统是否为深色模式
    @MainActor
    static var isDarkMode: Bool {
        let style = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String
        return style?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    /// 设置系统外观
    @MainActor
    static func setDarkMode(_ enabled: Bool) throws {
        let source = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to \(enabled ? "true" : "false")
            end tell
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw AppearanceError.scriptFailure(L("error.scriptInit"))
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? L("error.unknown")
            throw AppearanceError.scriptFailure(message)
        }
    }

    /// 在深色 / 浅色之间切换
    @MainActor
    static func toggle() throws {
        try setDarkMode(!isDarkMode)
    }
}
