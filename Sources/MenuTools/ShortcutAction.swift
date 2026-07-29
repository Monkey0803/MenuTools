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
            launchFirstAvailable(["/System/Applications/Mission Control.app"])
        case .launchpad:
            // macOS 26 以 Apps.app（“应用”启动器）取代 Launchpad；旧系统回退 Launchpad.app
            launchFirstAvailable(["/System/Applications/Launchpad.app", "/System/Applications/Apps.app"])
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

    /// 依次尝试多个路径，打开第一个存在的 App（适配不同 macOS 版本的系统 App）
    private func launchFirstAvailable(_ paths: [String]) {
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config)
    }
}

/// 系统按键模拟（需“辅助功能”权限）
enum KeySimulator {
    /// 先等物理修饰键释放再投递：触发热键时用户仍按住 ⌥⌘，而系统对“移动空间”等
    /// 符号热键按实时物理修饰键状态判定，必须等 ⌥⌘ 松开后，合成的 ⌃← 才不被污染。
    @MainActor
    static func post(key: CGKeyCode, flags: CGEventFlags) {
        Task { @MainActor in
            // 先给物理触发键（⌥⌘）一点时间释放，再注入干净的合成序列
            try? await Task.sleep(for: .milliseconds(80))
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            // 用 flagsChanged 显式按下修饰键：直接覆盖系统当前修饰键状态（即使物理 ⌥⌘ 仍按住），
            // 形成真实的“⌃按下→方向键→⌃松开”序列，空间切换等符号热键才能识别。
            let modKey = modifierKeyCode(for: flags)
            if let modKey, let fc = CGEvent(keyboardEventSource: source, virtualKey: modKey, keyDown: true) {
                fc.type = .flagsChanged
                fc.flags = flags
                fc.post(tap: .cghidEventTap)
            }
            if let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
                down.flags = flags
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
                up.flags = flags
                up.post(tap: .cghidEventTap)
            }
            if let modKey, let fc = CGEvent(keyboardEventSource: source, virtualKey: modKey, keyDown: false) {
                fc.type = .flagsChanged
                fc.flags = []
                fc.post(tap: .cghidEventTap)
            }
        }
    }

    /// 修饰键标志 → 对应修饰键的虚拟键码（用于 flagsChanged 事件）
    private static func modifierKeyCode(for flags: CGEventFlags) -> CGKeyCode? {
        if flags.contains(.maskControl) { return CGKeyCode(kVK_Control) }
        if flags.contains(.maskCommand) { return CGKeyCode(kVK_Command) }
        if flags.contains(.maskAlternate) { return CGKeyCode(kVK_Option) }
        if flags.contains(.maskShift) { return CGKeyCode(kVK_Shift) }
        return nil
    }
}

/// 一个快捷键组合（Carbon keyCode + Carbon 修饰符）
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String
}
