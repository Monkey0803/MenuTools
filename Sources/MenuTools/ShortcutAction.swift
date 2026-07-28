import AppKit
import Carbon.HIToolbox

/// 可绑定全局快捷键的系统动作
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case missionControl
    case launchpad
    case spotlight
    case dictation
    case doNotDisturb
    case showDesktop
    case quitApp
    case moveLeftSpace
    case moveRightSpace

    var id: String { rawValue }
    var titleKey: String { "sc.action.\(rawValue)" }

    var symbol: String {
        switch self {
        case .missionControl: return "square.grid.3x2"
        case .launchpad: return "square.grid.3x3.fill"
        case .spotlight: return "magnifyingglass"
        case .dictation: return "mic"
        case .doNotDisturb: return "moon.fill"
        case .showDesktop: return "menubar.dock.rectangle"
        case .quitApp: return "xmark.circle"
        case .moveLeftSpace: return "arrow.left.to.line"
        case .moveRightSpace: return "arrow.right.to.line"
        }
    }

    /// 执行该动作：应用类用 NSWorkspace，其余用系统按键模拟（需辅助功能权限）
    @MainActor
    func perform() {
        switch self {
        case .missionControl:
            launchApp("/System/Applications/Mission Control.app")
        case .launchpad:
            launchApp("/System/Applications/Launchpad.app")
        case .spotlight:
            KeySimulator.post(key: CGKeyCode(kVK_Space), flags: .maskCommand)
        case .dictation:
            // 听写默认由连按两次 fn 触发（依系统设置而定，属尽力而为）
            KeySimulator.post(key: CGKeyCode(kVK_Function), flags: [])
            KeySimulator.post(key: CGKeyCode(kVK_Function), flags: [])
        case .doNotDisturb:
            // 打开控制中心的“专注模式”（无公开切换 API，属尽力而为）
            KeySimulator.post(key: CGKeyCode(kVK_F11), flags: .maskControl)
        case .showDesktop:
            KeySimulator.post(key: CGKeyCode(kVK_F11), flags: .maskSecondaryFn)
        case .quitApp:
            KeySimulator.post(key: CGKeyCode(kVK_ANSI_Q), flags: .maskCommand)
        case .moveLeftSpace:
            KeySimulator.post(key: CGKeyCode(kVK_LeftArrow), flags: .maskControl)
        case .moveRightSpace:
            KeySimulator.post(key: CGKeyCode(kVK_RightArrow), flags: .maskControl)
        }
    }

    private func launchApp(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

/// 系统按键模拟（需“辅助功能”权限）
enum KeySimulator {
    static func post(key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}

/// 一个快捷键组合（Carbon keyCode + Carbon 修饰符）
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String
}
