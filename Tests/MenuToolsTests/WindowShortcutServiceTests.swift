import Foundation
import Testing
@testable import MenuTools

@Test("窗口快捷键能匹配布局")
func windowShortcutMatchesLayout() {
    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let bindings = [WindowLayout.maxWidth: binding]

    #expect(WindowShortcutCatalog.match(
        keyCode: 18,
        modifiers: GlobalShortcutModifier.controlOption,
        bindings: bindings
    ) == .maxWidth)
    #expect(WindowShortcutCatalog.match(keyCode: 19, modifiers: 0, bindings: bindings) == nil)
}

@Test("窗口快捷键能发现重复绑定")
func windowShortcutDetectsConflict() {
    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let bindings = [WindowLayout.maxWidth: binding, WindowLayout.centered: binding]

    #expect(WindowShortcutCatalog.conflict(for: binding, excluding: .maxWidth, in: bindings) == .centered)
}

@Test("窗口快捷键服务可以持久化绑定")
@MainActor
func windowShortcutServicePersistsBinding() throws {
    let suiteName = "MenuToolsTests.WindowShortcutService.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let service = WindowShortcutService(defaults: defaults)
    try service.setBinding(binding, for: .maxWidth)

    let restored = WindowShortcutService(defaults: defaults)
    #expect(restored.binding(for: .maxWidth) == binding)
}
