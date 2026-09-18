import Testing
import SwiftUI
@testable import MenuTools

@Test("主面板分类完整覆盖功能且不受常用项影响")
func menuPanelNavigationCoversAllFeatures() {
    let all = Set(BuiltInPluginID.allCases)
    let categorized = MenuPanelCategory.allCases.filter { $0 != .favorites }.flatMap {
        MenuPanelNavigation.items(in: $0, enabledPlugins: all, pinned: [])
    }
    #expect(Set(categorized) == Set(MenuPanelFeature.allCases))
    #expect(categorized.count == Set(categorized).count)
}

@Test("主面板隐藏已停用功能但保留用户的常用顺序")
func menuPanelNavigationFiltersWithoutLosingPins() {
    let pins: [MenuPanelFeature] = [.translation, .volume, .clipboard]
    #expect(MenuPanelNavigation.items(in: .favorites, enabledPlugins: [.appVolume, .clipboard], pinned: pins)
        == [.volume, .clipboard])
    #expect(MenuPanelNavigation.items(in: .favorites, enabledPlugins: [.translation, .appVolume, .clipboard], pinned: pins)
        == pins)
    #expect(MenuPanelNavigation.items(in: .network, enabledPlugins: [], pinned: pins).isEmpty)
}

@Test("常用配置兼容未知功能并区分空配置和初始配置")
func menuPanelNavigationRestoresPreferences() {
    #expect(MenuPanelNavigation.decodePins("") == MenuPanelNavigation.defaultPins)
    #expect(MenuPanelNavigation.decodePins("[]").isEmpty)
    #expect(MenuPanelNavigation.decodePins("[\"volume\",\"unknown\",\"volume\",\"clipboard\"]") == [.volume, .clipboard])
    let pins: [MenuPanelFeature] = [.clipboard, .volume]
    #expect(MenuPanelNavigation.decodePins(MenuPanelNavigation.encodePins(pins)) == pins)
    #expect(MenuPanelNavigation.category(for: "removed") == .favorites)
}

@Test("组合功能至少有一个支持插件时才展示")
func menuPanelNavigationChecksCombinedFeatures() {
    #expect(MenuPanelFeature.quickActions.isAvailable(enabledPlugins: [.screenshot]))
    #expect(!MenuPanelFeature.quickActions.isAvailable(enabledPlugins: [.translation]))
    #expect(MenuPanelFeature.hero.isAvailable(enabledPlugins: [.finderTools]))
    #expect(MenuPanelFeature.hero.isAvailable(enabledPlugins: [.systemControls]))
}

@Test("分类玻璃块拖动按落点选中且越界吸附首尾")
func menuPanelGlassDragSelectsDestination() {
    #expect(MenuPanelCategoryDragLayout.category(at: -100, width: 328) == .favorites)
    #expect(MenuPanelCategoryDragLayout.category(at: 67, width: 328) == .favorites)
    #expect(MenuPanelCategoryDragLayout.category(at: 68, width: 328) == .system)
    #expect(MenuPanelCategoryDragLayout.category(at: 164, width: 328) == .devices)
    #expect(MenuPanelCategoryDragLayout.category(at: 1000, width: 328) == .tools)
}

@Test("分类玻璃块中心始终留在轨道内且可恢复选中位置")
func menuPanelGlassDragClampsAndRestoresCenter() {
    #expect(MenuPanelCategoryDragLayout.clampedCenter(-100, width: 328) == 36)
    #expect(MenuPanelCategoryDragLayout.clampedCenter(1000, width: 328) == 292)
    #expect(MenuPanelCategoryDragLayout.clampedCenter(145, width: 328) == 145)
    for category in MenuPanelCategory.allCases {
        let center = MenuPanelCategoryDragLayout.center(for: category, width: 328)
        #expect(MenuPanelCategoryDragLayout.category(at: center, width: 328) == category)
    }
    #expect(MenuPanelCategoryDragLayout.category(at: .nan, width: 0) == .favorites)
}
