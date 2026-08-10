import Testing
@testable import MenuTools

@Test("配置场景包含预期动作")
func scenePresetsContainExpectedActions() {
    #expect(ScenePreset.work.actions.contains(.openFavoriteApps))
    #expect(ScenePreset.work.actions.contains(.enableFocus))
    #expect(ScenePreset.demo.actions.contains(.preventSleep))
    #expect(ScenePreset.demo.actions.contains(.hideDesktopFiles))
    #expect(ScenePreset.night.actions.contains(.enableNightShift))
    #expect(ScenePreset.night.actions.contains(.muteAudio))
}

@Test("配置场景名称和图标可用于菜单展示")
func scenePresetsHavePresentationMetadata() {
    #expect(ScenePreset.allCases.count == 3)
    #expect(ScenePreset.allCases.allSatisfy { !$0.titleKey.isEmpty && !$0.symbol.isEmpty })
}
