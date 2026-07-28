import SwiftUI

/// 全局设置的存取 Key
enum SettingsKey {
    static let menuBarIcon = "menuBarIcon"
    static let preferredTerminal = "preferredTerminal"
    static let autoCheckUpdate = "autoCheckUpdateEnabled"
    static let appLanguage = "appLanguage"
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
        case .wrench: return L("icon.wrench")
        case .terminal: return L("icon.terminal")
        case .sparkles: return L("icon.sparkles")
        case .bolt: return L("icon.bolt")
        case .cube: return L("icon.cube")
        case .moon: return L("icon.moon")
        case .gear: return L("icon.gear")
        case .paw: return L("icon.paw")
        }
    }

    static let `default` = MenuBarIcon.wrench
}

@main
struct MenuToolsApp: App {
    @AppStorage(SettingsKey.menuBarIcon) private var menuBarIcon = MenuBarIcon.default.rawValue

    init() {
        // 注册已保存的全局快捷键
        ShortcutManager.shared.activate()
    }

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
