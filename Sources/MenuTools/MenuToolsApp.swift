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
    // 截图
    static let screenshotMode = "screenshot.mode"
    static let screenshotCopy = "screenshot.copyToClipboard"
    static let screenshotEdit = "screenshot.openEditor"
    static let screenshotLastRegion = "screenshot.lastRegion"
    // 保留旧存储键，升级后不丢失已有的长截图区域选择设置。
    static let screenshotLongSelectRegion = "screenshot.longSelectWindow"
    static let screenshotSaveToDisk = "screenshot.saveToDisk"
    static let screenshotDirectory = "screenshot.directory"
    static let screenshotFormat = "screenshot.format"
    static let screenshotNamingTemplate = "screenshot.namingTemplate"
    static let screenshotHistory = "screenshot.history"
    static let screenshotOCRShortcut = "screenshot.ocrShortcut"
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
    init() {
        // Sparkle 必须由主 App 持有并在应用启动时启动，自动检查和安装流程才能跨面板生命周期工作。
        _ = SparkleUpdateService.shared
        // 使用 AppKit 原生状态项接收鼠标点击，面板内容仍由 SwiftUI 渲染。
        MenuBarStatusItemController.shared.start()
        // 根据配置启动平滑滚动引擎
        SmoothScrollEngine.shared.activateIfEnabled()
        // 监听 Finder 扩展转交的右键操作指令（沙箱扩展无法直接执行文件操作）
        RightClickCommandHandler.activate()
        // 剪贴板历史必须独立于菜单栏面板持续监听
        ClipboardHistoryService.shared.startMonitoring()
        // App 音量进程枚举和输出设备监听必须独立于面板生命周期持续运行。
        AppVolumeService.shared.start()
        // 截图历史只保留仍存在的文件，避免 Quick Access 显示已被 Finder 删除的条目。
        ScreenshotHistoryStore.shared.pruneMissingFiles()
        // 全局快捷键必须独立于面板生命周期持续监听
        GlobalShortcutService.shared.start()
        // 应用快捷键必须独立于设置页面生命周期持续监听
        AppShortcutService.shared.start()
        // 窗口布局快捷键必须独立于设置页面生命周期持续监听
        WindowShortcutService.shared.start()
        // 截图快捷键必须独立于设置页面生命周期持续监听
        ScreenshotShortcutService.shared.start()
        ScreenshotRegionOCRService.shared.start()
        // 窗口管理器的应用规则和边缘吸附必须独立于设置页面持续运行
        WindowManagementService.shared.start()
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
