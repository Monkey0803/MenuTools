import SwiftUI

/// 全局设置的存取 Key
enum SettingsKey {
    static let menuBarIcon = "menuBarIcon"
    static let menuBarShowTitle = "menuBarShowTitle"   // 菜单栏是否同时显示标题
    static let togglesShowTitle = "togglesShowTitle"   // 面板快捷开关是否显示标题
    static let preferredTerminal = "preferredTerminal"
    static let autoCheckUpdate = "autoCheckUpdateEnabled"
    static let appLanguage = "appLanguage"
    // 平滑滚动
    static let scrollEnabled = "scrollEnabled"
    static let scrollSmoothV = "scrollSmoothVertical"
    static let scrollSmoothH = "scrollSmoothHorizontal"
    static let scrollInvertV = "scrollInvertVertical"
    static let scrollInvertH = "scrollInvertHorizontal"
    static let scrollGain = "scrollGain"
    static let scrollDuration = "scrollDuration"
    static let scrollMinStep = "scrollMinStep"
    static let scrollTouchpad = "scrollTouchpadEmulation"
    static let scrollAccelKey = "scrollAccelModifier"   // 加速键修饰符（Cocoa rawValue）
    static let scrollShiftKey = "scrollShiftModifier"   // 转换键
    static let scrollDisableKey = "scrollDisableModifier" // 禁用键
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
    @AppStorage(SettingsKey.menuBarShowTitle) private var showMenuBarTitle = false

    init() {
        // 注册已保存的全局快捷键
        ShortcutManager.shared.activate()
        // 根据配置启动平滑滚动引擎
        SmoothScrollEngine.shared.activateIfEnabled()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
        } label: {
            if showMenuBarTitle {
                Label("MenuTools", systemImage: menuBarIcon)
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: menuBarIcon)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
