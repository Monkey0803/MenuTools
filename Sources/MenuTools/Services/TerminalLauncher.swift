import AppKit
import Foundation

/// 支持的终端 App，按优先级排列
enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal = "com.apple.Terminal"
    case iterm = "com.googlecode.iterm2"
    case warp = "dev.warp.Warp-Stable"
    case ghostty = "com.mitchellh.ghostty"
    case kitty = "net.kovidgoyal.kitty"
    case alacritty = "org.alacritty"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terminal: return L("terminal.builtin")
        case .iterm: return "iTerm2"
        case .warp: return "Warp"
        case .ghostty: return "Ghostty"
        case .kitty: return "kitty"
        case .alacritty: return "Alacritty"
        }
    }

    /// 紧凑展示用短名
    var shortName: String {
        switch self {
        case .terminal: return "Terminal"
        default: return displayName
        }
    }

    /// 该终端在本机的安装位置
    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue)
    }

    /// 本机已安装的终端列表
    static var installed: [TerminalApp] {
        allCases.filter { $0.appURL != nil }
    }

    /// 默认终端：取已安装列表的第一个（系统自带的“终端”永远存在）
    static var systemDefault: TerminalApp {
        installed.first ?? .terminal
    }
}

/// 在指定终端中打开目录
enum TerminalLauncher {

    enum LaunchError: LocalizedError {
        case appNotFound(TerminalApp)

        var errorDescription: String? {
            switch self {
            case .appNotFound(let app):
                return L("error.terminalNotFound", app.displayName)
            }
        }
    }

    @MainActor
    static func open(directory: URL, in terminal: TerminalApp) throws {
        guard let appURL = terminal.appURL else {
            throw LaunchError.appNotFound(terminal)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([directory], withApplicationAt: appURL, configuration: configuration)
    }
}
