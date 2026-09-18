import AppKit
import Foundation

extension TerminalApp {
    var displayName: String {
        switch self {
        case .terminal: return L("terminal.builtin")
        default: return shortName
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
