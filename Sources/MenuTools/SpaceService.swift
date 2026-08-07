import AppKit
import Carbon.HIToolbox

/// 使用 macOS 标准的 Control+方向键切换空间。
/// 通过 System Events 保留系统原生的空间切换动画和菜单栏状态。
enum SpaceMoveResult: Equatable {
    case success
    case automationRequired
    case executionFailed(String)
}

enum SpaceService {
    @MainActor
    static func moveResult(next: Bool) -> SpaceMoveResult {
        let keyCode = next ? kVK_RightArrow : kVK_LeftArrow
        guard let script = NSAppleScript(source: SpaceShortcutScript.source(keyCode: keyCode)) else {
            return .executionFailed(L("space.scriptInitFailed"))
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return result(for: error)
    }

    /// 保留旧 Bool 入口，供旧动作实现继续使用。
    @MainActor
    @discardableResult
    static func move(next: Bool) -> Bool {
        if case .success = moveResult(next: next) {
            return true
        }
        return false
    }

    static func result(for error: NSDictionary?) -> SpaceMoveResult {
        guard let error else { return .success }
        if let number = error["NSAppleScriptErrorNumber"] as? NSNumber, number.intValue == -1743 {
            return .automationRequired
        }
        let message = error["NSAppleScriptErrorMessage"] as? String
        if let message {
            return .executionFailed(L("space.executionFailed", message))
        }
        return .executionFailed(L("space.executionFailed", L("error.unknown")))
    }
}

/// 生成由 System Events 执行的系统空间切换脚本，便于纯逻辑测试。
enum SpaceShortcutScript {
    static func source(keyCode: Int) -> String {
        """
        tell application "System Events"
            key code \(keyCode) using control down
        end tell
        """
    }
}
