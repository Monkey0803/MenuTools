import Foundation
import SwiftUI

enum MenuPanelLayout {
    static let width: CGFloat = 360
    static let height: CGFloat = 640
}

enum MenuPanelCategory: String, CaseIterable, Identifiable {
    case favorites, system, devices, network, tools

    var id: String { rawValue }
    var titleKey: String { "panel.category.\(rawValue)" }
}

enum MenuPanelFeature: String, CaseIterable, Identifiable {
    case toggles, resources, storage, cleanup
    case volume, bluetooth, display, battery
    case network, traffic
    case hero, translation, clipboard, quickActions, scenes, shortcuts, focus

    var id: String { rawValue }

    var category: MenuPanelCategory {
        switch self {
        case .toggles, .resources, .storage, .cleanup: .system
        case .volume, .bluetooth, .display, .battery: .devices
        case .network, .traffic: .network
        case .hero, .translation, .clipboard, .quickActions, .scenes, .shortcuts, .focus: .tools
        }
    }

    var titleKey: String {
        switch self {
        case .toggles: "plugin.system-controls.title"
        case .resources: "resource.title"
        case .storage: "storage.title"
        case .cleanup: "cleanup.derivedData"
        case .volume: "volume.title"
        case .bluetooth: "bt.device"
        case .display: "display.title"
        case .battery: "batteryHealth.title"
        case .network: "network.title"
        case .traffic: "plugin.network-traffic.title"
        case .hero: "panel.feature.hero"
        case .translation: "plugin.translation.title"
        case .clipboard: "clipboard.history"
        case .quickActions: "quickAction.title"
        case .scenes: "scene.title"
        case .shortcuts: "shortcut.title"
        case .focus: "focus.title"
        }
    }

    func isAvailable(enabledPlugins: Set<BuiltInPluginID>) -> Bool {
        let supportingPlugins: Set<BuiltInPluginID> = switch self {
        case .toggles: [.systemControls]
        case .resources: [.systemResources]
        case .storage, .cleanup, .bluetooth, .display, .battery, .network: [.systemInsights]
        case .volume: [.appVolume]
        case .traffic: [.networkTraffic]
        case .hero: [.systemControls, .finderTools]
        case .translation: [.translation]
        case .clipboard: [.clipboard]
        case .quickActions: [.systemControls, .finderTools, .screenshot]
        case .scenes, .shortcuts, .focus: [.automation]
        }
        return !supportingPlugins.isDisjoint(with: enabledPlugins)
    }
}

enum MenuPanelNavigation {
    static let categoryKey = "panel.selectedCategory.v1"
    static let pinsKey = "panel.pinnedFeatures.v1"
    static let defaultPins: [MenuPanelFeature] = [.toggles, .volume, .clipboard]

    static func category(for rawValue: String) -> MenuPanelCategory {
        MenuPanelCategory(rawValue: rawValue) ?? .favorites
    }

    static func items(
        in category: MenuPanelCategory,
        enabledPlugins: Set<BuiltInPluginID>,
        pinned: [MenuPanelFeature]
    ) -> [MenuPanelFeature] {
        let candidates = category == .favorites
            ? pinned
            : MenuPanelFeature.allCases.filter { $0.category == category }
        return candidates.filter { $0.isAvailable(enabledPlugins: enabledPlugins) }
    }

    static func decodePins(_ value: String) -> [MenuPanelFeature] {
        guard let data = value.data(using: .utf8),
              let identifiers = try? JSONDecoder().decode([String].self, from: data) else {
            return defaultPins
        }
        var seen: Set<MenuPanelFeature> = []
        return identifiers.compactMap(MenuPanelFeature.init(rawValue:)).filter { seen.insert($0).inserted }
    }

    static func encodePins(_ features: [MenuPanelFeature]) -> String {
        let data = try? JSONEncoder().encode(features.map(\.rawValue))
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

private struct MenuPanelGroupedSurfacesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var menuPanelGroupedSurfaces: Bool {
        get { self[MenuPanelGroupedSurfacesKey.self] }
        set { self[MenuPanelGroupedSurfacesKey.self] = newValue }
    }
}

/// 主面板的内容层使用语义化分组底色，避免与上方玻璃导航争抢视觉层级。
struct MenuPanelContentSurface: ViewModifier {
    @Environment(\.menuPanelGroupedSurfaces) private var grouped
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false
    let tint: Color?
    let selected: Bool
    let interactive: Bool
    let shape: AnyShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if grouped {
            content
                .background(.quaternary.opacity(selected || isHovered ? 0.9 : 0.5), in: shape)
                .overlay {
                    shape.stroke(.separator, lineWidth: contrast == .increased ? 1 : 0.5)
                        .allowsHitTesting(false)
                }
                .onHover { isHovered = interactive && $0 }
        } else {
            content.modifier(ControlCenterSurface(
                tint: tint, selected: selected, interactive: interactive, shape: shape
            ))
        }
    }
}
