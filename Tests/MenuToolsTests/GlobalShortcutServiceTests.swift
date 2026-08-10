import Testing
@testable import MenuTools

@Test("全局快捷键能匹配对应场景")
func globalShortcutMatchesScene() {
    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let bindings = [ScenePreset.work: binding]

    #expect(GlobalShortcutCatalog.match(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption, bindings: bindings) == .work)
    #expect(GlobalShortcutCatalog.match(keyCode: 19, modifiers: GlobalShortcutModifier.controlOption, bindings: bindings) == nil)
}

@Test("全局快捷键能发现冲突")
func globalShortcutDetectsConflict() {
    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let bindings = [ScenePreset.work: binding, ScenePreset.demo: binding]

    #expect(GlobalShortcutCatalog.conflict(for: binding, excluding: .work, in: bindings) == .demo)
}

@Test("默认场景快捷键使用不同组合")
func globalShortcutDefaultsAreDistinct() {
    let values = Array(GlobalShortcutCatalog.defaults.values)
    #expect(Set(values).count == values.count)
}
