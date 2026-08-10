import AppKit
import Foundation
import Observation

enum FocusModeParser {
    static func state(from output: String) -> Bool? {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "enabled", "on", "true", "1": return true
        case "disabled", "off", "false", "0": return false
        default: return nil
        }
    }
}

enum FocusModeScript {
    /// 通过 Control Center 的辅助功能层切换系统专注模式；未授权时由服务回退到设置页。
    static let toggle = """
    tell application "System Events"
        tell process "ControlCenter"
            click menu bar item "Control Center" of menu bar 1
            delay 0.25
            set focusItems to every UI element of window 1 whose description contains "Focus"
            if (count of focusItems) is 0 then error number -1708
            click item 1 of focusItems
        end tell
    end tell
    """

    static let readState = """
    tell application "System Events"
        tell process "ControlCenter"
            click menu bar item "Control Center" of menu bar 1
            delay 0.25
            set state to "unknown"
            set focusItems to every UI element of window 1 whose description contains "Focus"
            if (count of focusItems) is not 0 then
                set focusItem to item 1 of focusItems
                try
                    if value of focusItem is "1" then set state to "enabled"
                    if value of focusItem is "0" then set state to "disabled"
                end try
            end if
            key code 53
            return state
        end tell
    end tell
    """
}

enum FocusModeError: LocalizedError, Equatable {
    case unavailable
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return L("focus.error.unavailable")
        case let .operationFailed(message): return L("focus.error.operation", message)
        }
    }
}

@MainActor
@Observable
final class FocusModeService {
    private(set) var isEnabled: Bool?
    private(set) var isBusy = false

    func refresh() {
        isEnabled = nil
        guard let script = NSAppleScript(source: FocusModeScript.readState) else { return }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil, let value = result.stringValue else { return }
        isEnabled = FocusModeParser.state(from: value)
    }

    func toggle() throws {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard let script = NSAppleScript(source: FocusModeScript.toggle) else {
            throw FocusModeError.unavailable
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? L("error.unknown")
            throw FocusModeError.operationFailed(message)
        }
        refresh()
    }

    func openSettings() throws {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Focus") else {
            throw FocusModeError.unavailable
        }
        guard NSWorkspace.shared.open(url) else { throw FocusModeError.unavailable }
    }
}
