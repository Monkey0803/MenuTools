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

@Test("功能中心筛选器只展示符合状态的模块")
func pluginCenterFilterMatchesRuntimeState() {
    #expect(PluginCenterFilter.all.includes(isEnabled: false, state: .stopped))
    #expect(PluginCenterFilter.enabled.includes(isEnabled: true, state: .running))
    #expect(!PluginCenterFilter.enabled.includes(isEnabled: false, state: .stopped))
    #expect(PluginCenterFilter.attention.includes(isEnabled: true, state: .failed("error")))
    #expect(!PluginCenterFilter.attention.includes(isEnabled: true, state: .running))
}
