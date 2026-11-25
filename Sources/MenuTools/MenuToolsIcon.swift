import AppKit
import SwiftUI

enum MenuToolsIconCatalog {
    static func name(for pluginID: BuiltInPluginID) -> String {
        switch pluginID {
        case .systemControls: "toggle-sliders"
        case .systemInsights: "dashboard-grid"
        case .systemResources: "gauge"
        case .systemStorage: "hard-drive"
        case .menuBarOrganizer: "menu-bar"
        case .networkTraffic: "network-arrows"
        case .clipboard: "clipboard"
        case .textActions: "text-cursor"
        case .translation: "speech-bubble"
        case .appVolume: "speaker"
        case .screenshot: "viewfinder"
        case .windowManagement: "window-layout"
        case .appLauncher: "app-grid"
        case .automation: "magic-wand"
        case .finderTools: "cursor-arrow"
        case .smoothScroll: "mouse"
        }
    }

    static func name(for tab: SettingsTab) -> String {
        switch tab {
        case .general: "gear"
        case .plugins: "plugin-grid"
        case .runtimeStatus, .healthCheck: "shield-check"
        case .networkTraffic: "network-arrows"
        case .volume: "speaker"
        case .rightClick: "cursor-arrow"
        case .scroll: "mouse"
        case .windowManagement: "window-layout"
        case .appLaunch: "app-grid"
        case .screenshot: "viewfinder"
        case .clipboard: "clipboard"
        case .textActions: "text-cursor"
        case .translation: "speech-bubble"
        case .systemResources: "gauge"
        case .systemStorage: "hard-drive"
        case .menuBarOrganizer: "menu-bar"
        }
    }
}

/// 加载打包后的自定义 SVG，并作为模板图像继承 SwiftUI 的语义化前景色。
/// 开发环境缺少 App Bundle 资源时保留 SF Symbol 回退，避免图标区域变为空白。
struct MenuToolsIcon: View {
    let name: String
    let fallbackSystemName: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image = MenuToolsIconLoader.image(named: name) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSystemName)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
private enum MenuToolsIconLoader {
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "Icons"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
