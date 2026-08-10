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
    /// 菜单栏项目的 description 会随系统语言变化，不能固定写死英文标题。
    private static let clickControlCenter = """
            set centerItems to every menu bar item of menu bar 1 whose description contains "Control Center" or description contains "控制中心"
            if (count of centerItems) is 0 then error number -1708
            click item 1 of centerItems
    """

    /// 通过 Control Center 的辅助功能层切换系统专注模式；未授权时由服务回退到设置页。
    static let toggle = """
    tell application "System Events"
        tell process "ControlCenter"
        \(clickControlCenter)
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
        \(clickControlCenter)
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

    static let toggleDoNotDisturb = """
    tell application "System Events"
        tell process "ControlCenter"
        \(clickControlCenter)
            delay 0.25
            set focusItems to every UI element of window 1 whose description contains "Focus"
            if (count of focusItems) is 0 then error number -1708
            click item 1 of focusItems
            delay 0.25
            set dndItems to every UI element of entire contents of window 1 whose description contains "Do Not Disturb" or description contains "勿扰" or description contains "勿擾"
            if (count of dndItems) is 0 then error number -1708
            click item 1 of dndItems
        end tell
    end tell
    """

    static let readDoNotDisturb = """
    tell application "System Events"
        tell process "ControlCenter"
        \(clickControlCenter)
            delay 0.25
            set state to "unknown"
            set dndItems to every UI element of entire contents of window 1 whose description contains "Do Not Disturb" or description contains "勿扰" or description contains "勿擾"
            if (count of dndItems) is not 0 then
                try
                    if value of item 1 of dndItems is "1" then set state to "enabled"
                    if value of item 1 of dndItems is "0" then set state to "disabled"
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
    static let shared = FocusModeService()

    private(set) var isEnabled: Bool?
    private(set) var isDoNotDisturbEnabled: Bool?
    private(set) var isBusy = false

    func refresh() {
        isEnabled = nil
        isDoNotDisturbEnabled = nil
        isEnabled = state(using: FocusModeScript.readState)
        isDoNotDisturbEnabled = state(using: FocusModeScript.readDoNotDisturb)
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

    func toggleDoNotDisturb() throws {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard let script = NSAppleScript(source: FocusModeScript.toggleDoNotDisturb) else {
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

    private func state(using source: String) -> Bool? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil, let value = result.stringValue else { return nil }
        return FocusModeParser.state(from: value)
    }
}
