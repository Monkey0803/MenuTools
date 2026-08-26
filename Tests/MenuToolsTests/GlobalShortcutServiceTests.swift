import Foundation
import Testing
@testable import MenuTools

private struct StubShortcutConflictChecker: ShortcutConflictChecking {
    let source: ShortcutConflictSource?

    func conflict(for shortcut: GlobalShortcut, context: ShortcutConflictContext) -> ShortcutConflictSource? {
        source
    }
}

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

@Test("快捷键显示包含字母名称")
func globalShortcutDisplayIncludesLetterName() {
    #expect(GlobalShortcut.keyName(for: 0) == "A")
    #expect(GlobalShortcut(keyCode: 0, modifiers: GlobalShortcutModifier.controlOption).displayName == "⌃⌥A")
    #expect(GlobalShortcut.keyName(for: 46) == "M")
}

@Test("场景快捷键可以发现窗口快捷键交叉冲突")
func globalShortcutDetectsWindowConflict() {
    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let bindings = [WindowLayout.maxWidth: binding]

    #expect(ShortcutBindingConflictCatalog.windowConflict(for: binding, in: bindings) == .maxWidth)
}

@Test("快捷键冲突检测可以识别系统快捷键")
@MainActor
func globalShortcutRejectsSystemConflict() throws {
    let suiteName = "MenuToolsTests.GlobalShortcutConflict.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let service = GlobalShortcutService(
        defaults: defaults,
        conflictChecker: StubShortcutConflictChecker(source: .system)
    )

    #expect(throws: GlobalShortcutError.systemConflict) {
        try service.setBinding(binding, for: .work)
    }
}

@Test("快捷键冲突检测可以识别其他应用占用")
@MainActor
func globalShortcutRejectsOtherApplicationConflict() throws {
    let suiteName = "MenuToolsTests.GlobalShortcutExternalConflict.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let binding = GlobalShortcut(keyCode: 19, modifiers: GlobalShortcutModifier.controlOption)
    let service = GlobalShortcutService(
        defaults: defaults,
        conflictChecker: StubShortcutConflictChecker(source: .otherApplication)
    )

    #expect(throws: GlobalShortcutError.otherApplicationConflict) {
        try service.setBinding(binding, for: .demo)
    }
}

@Test("全局快捷键能发现截图快捷键冲突")
@MainActor
func globalShortcutRejectsScreenshotConflict() throws {
    let suiteName = "MenuToolsTests.ScreenshotShortcutConflict.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let binding = GlobalShortcut(keyCode: 19, modifiers: GlobalShortcutModifier.controlOption)
    let service = GlobalShortcutService(
        defaults: defaults,
        conflictChecker: StubShortcutConflictChecker(source: .screenshot)
    )

    #expect(throws: GlobalShortcutError.screenshotConflict) {
        try service.setBinding(binding, for: .demo)
    }
}
