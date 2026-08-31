import Testing
@testable import MenuTools

@Test("功能中心和通用设置始终可见，插件设置随启用状态变化")
func settingsTabsFollowEnabledPlugins() {
    let tabs = SettingsTab.visibleTabs(enabledPluginIDs: [.appVolume, .screenshot])

    #expect(tabs.contains(.general))
    #expect(tabs.contains(.plugins))
    #expect(tabs.contains(.volume))
    #expect(tabs.contains(.screenshot))
    #expect(!tabs.contains(.rightClick))
    #expect(!tabs.contains(.scroll))
    #expect(!tabs.contains(.windowManagement))
    #expect(!tabs.contains(.appLaunch))
}

@Test("禁用当前设置页时回退到功能中心")
func unavailableSettingsTabFallsBackToPluginCenter() {
    #expect(SettingsTab.fallback(for: .volume, enabledPluginIDs: []) == .plugins)
    #expect(SettingsTab.fallback(for: .general, enabledPluginIDs: []) == .general)
}

@Test("侧边栏固定设置与已启用功能分组互不混合")
func sidebarSeparatesPrimaryAndFeatureDestinations() {
    #expect(SettingsTab.primaryTabs == [.general, .plugins])
    #expect(SettingsTab.enabledFeatureTabs(enabledPluginIDs: [.appVolume, .windowManagement]) == [
        .volume,
        .windowManagement
    ])
}

@Test("启用剪贴板后会显示在已启用功能中")
func clipboardAppearsInEnabledFeatureSettings() {
    #expect(SettingsTab.enabledFeatureTabs(enabledPluginIDs: [.clipboard]) == [.clipboard])
}

@Test("功能中心筛选器只展示符合状态的模块")
func pluginCenterFilterMatchesRuntimeState() {
    #expect(PluginCenterFilter.all.includes(isEnabled: false, state: .stopped))
    #expect(PluginCenterFilter.enabled.includes(isEnabled: true, state: .running))
    #expect(!PluginCenterFilter.enabled.includes(isEnabled: false, state: .stopped))
    #expect(PluginCenterFilter.attention.includes(isEnabled: true, state: .failed("error")))
    #expect(!PluginCenterFilter.attention.includes(isEnabled: true, state: .running))
}

@Test("设置窗口侧边栏始终保持可见")
func settingsSidebarIsPersistent() {
    #expect(!SettingsSidebarPolicy.allowsCollapsing)
}

@Test("设置侧边栏使用透明 Liquid Glass 导航层次")
func settingsSidebarUsesTransparentLiquidGlassHierarchy() {
    #expect(!SettingsSidebarVisualPolicy.usesSystemListBackground)
    #expect(SettingsSidebarVisualPolicy.usesGlassSelection)
    #expect(!SettingsSidebarVisualPolicy.showsSystemFocusRing)
    #expect(SettingsSidebarVisualPolicy.selectionTintOpacity == 0.28)

    let idle = SettingsSidebarVisualPolicy.itemStyle(isSelected: false, isHovered: false)
    let hovered = SettingsSidebarVisualPolicy.itemStyle(isSelected: false, isHovered: true)
    let selected = SettingsSidebarVisualPolicy.itemStyle(isSelected: true, isHovered: false)

    #expect(!idle.showsGlass)
    #expect(idle.backgroundOpacity == 0)
    #expect(!hovered.showsGlass)
    #expect(hovered.backgroundOpacity > idle.backgroundOpacity)
    #expect(selected.showsGlass)
    #expect(selected.tintOpacity == SettingsSidebarVisualPolicy.selectionTintOpacity)
}

@Test("菜单面板入场动画总延迟保持短促")
func menuPanelEntranceDelayIsBounded() {
    #expect(MenuPanelEntranceTiming.delay(for: 0) == 0)
    #expect(MenuPanelEntranceTiming.delay(for: 15) <= 0.18)
}
