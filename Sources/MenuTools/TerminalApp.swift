import Foundation

/// App 与 Finder 扩展共用的终端标识，不包含安装探测和启动操作。
enum TerminalApp: String, CaseIterable, Identifiable, Sendable {
    case terminal = "com.apple.Terminal"
    case iterm = "com.googlecode.iterm2"
    case warp = "dev.warp.Warp-Stable"
    case ghostty = "com.mitchellh.ghostty"
    case kitty = "net.kovidgoyal.kitty"
    case alacritty = "org.alacritty"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .warp: return "Warp"
        case .ghostty: return "Ghostty"
        case .kitty: return "kitty"
        case .alacritty: return "Alacritty"
        }
    }

    static let defaultOptionID = "default"

    /// 显式选择仅作用于本次操作；旧指令与默认入口沿用用户偏好。
    static func resolve(optionID: String?, preferredID: String?, fallback: TerminalApp) -> TerminalApp? {
        if let optionID, optionID != defaultOptionID { return TerminalApp(rawValue: optionID) }
        return preferredID.flatMap(TerminalApp.init(rawValue:)) ?? fallback
    }
}
