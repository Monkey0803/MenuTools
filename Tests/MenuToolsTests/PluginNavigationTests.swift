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
