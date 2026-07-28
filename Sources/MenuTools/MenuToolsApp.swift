import SwiftUI

/// 全局设置的存取 Key
enum SettingsKey {
    static let menuBarIcon = "menuBarIcon"
    static let preferredTerminal = "preferredTerminal"
    static let autoCheckUpdate = "autoCheckUpdateEnabled"
}

/// 可选的菜单栏图标（SF Symbols）
enum MenuBarIcon: String, CaseIterable, Identifiable {
    case wrench = "wrench.and.screwdriver.fill"
    case terminal = "terminal.fill"
    case sparkles = "sparkles"
    case bolt = "bolt.fill"
    case cube = "cube.transparent"
    case moon = "moon.stars.fill"
    case gear = "gearshape.fill"
    case paw = "pawprint.fill"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wrench: return "工具"
        case .terminal: return "终端"
        case .sparkles: return "星光"
        case .bolt: return "闪电"
        case .cube: return "方块"
        case .moon: return "月亮"
        case .gear: return "齿轮"
        case .paw: return "爪印"
        }
    }

    static let `default` = MenuBarIcon.wrench
}

@main
struct MenuToolsApp: App {
    @AppStorage(SettingsKey.menuBarIcon) private var menuBarIcon = MenuBarIcon.default.rawValue

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
