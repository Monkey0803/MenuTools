import Testing
@testable import MenuTools

@Test("每个内置功能都有稳定的自定义图标名称")
func everyBuiltInPluginHasCustomIcon() {
    let names = BuiltInPluginID.allCases.map(MenuToolsIconCatalog.name(for:))

    #expect(names.count == BuiltInPluginID.allCases.count)
    #expect(Set(names).count == BuiltInPluginID.allCases.count)
    #expect(names.allSatisfy { !$0.isEmpty })
}

@Test("设置主入口使用同一套自定义图标")
func primarySettingsTabsUseCustomIcons() {
    #expect(MenuToolsIconCatalog.name(for: SettingsTab.general) == "gear")
    #expect(MenuToolsIconCatalog.name(for: SettingsTab.plugins) == "plugin-grid")
    #expect(MenuToolsIconCatalog.name(for: SettingsTab.runtimeStatus) == "shield-check")
    #expect(MenuToolsIconCatalog.name(for: SettingsTab.clipboard) == "clipboard")
    #expect(MenuToolsIconCatalog.name(for: SettingsTab.windowManagement) == "window-layout")
}
