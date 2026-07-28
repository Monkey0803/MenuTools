import AppKit
import Foundation

/// 与 Finder 交互：获取当前最前窗口的目录路径
enum FinderService {

    enum FinderError: LocalizedError {
        case scriptFailure(String)

        var errorDescription: String? {
            switch self {
            case .scriptFailure(let message):
                return L("error.finderPath", message)
            }
        }
    }

    /// 返回 Finder 最前窗口的 POSIX 路径；没有窗口时回退到桌面
    @MainActor
    static func frontWindowPath() throws -> URL {
        let source = """
        tell application "Finder"
            if (count of windows) > 0 then
                try
                    return POSIX path of (target of front window as alias)
                on error
                    return POSIX path of (path to desktop)
                end try
            else
                return POSIX path of (path to desktop)
            end if
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw FinderError.scriptFailure(L("error.scriptInit"))
        }
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? L("error.unknown")
            throw FinderError.scriptFailure(message)
        }
        guard let path = result.stringValue, !path.isEmpty else {
            throw FinderError.scriptFailure(L("error.emptyResult"))
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
