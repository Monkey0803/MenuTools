import Foundation
import Testing
@testable import MenuTools

private struct AppShortcutNoConflictChecker: ShortcutConflictChecking {
    func conflict(for shortcut: GlobalShortcut, context: ShortcutConflictContext) -> ShortcutConflictSource? {
        nil
    }
}

private struct AppShortcutStubConflictChecker: ShortcutConflictChecking {
    let source: ShortcutConflictSource?

    func conflict(for shortcut: GlobalShortcut, context: ShortcutConflictContext) -> ShortcutConflictSource? {
        source
    }
}

@Test("应用快捷键能匹配绑定的应用路径")
func appShortcutMatchesApplicationPath() {
    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let bindings = ["/Applications/Safari.app": binding]

    #expect(
        AppShortcutCatalog.match(
            keyCode: 18,
            modifiers: GlobalShortcutModifier.controlOption,
            bindings: bindings
        ) == "/Applications/Safari.app"
    )
    #expect(
        AppShortcutCatalog.match(
            keyCode: 19,
            modifiers: GlobalShortcutModifier.controlOption,
            bindings: bindings
        ) == nil
    )
}

@Test("应用快捷键能发现重复绑定")
func appShortcutDetectsConflict() {
    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let bindings = [
        "/Applications/Safari.app": binding,
        "/Applications/Notes.app": binding
    ]

    #expect(
        AppShortcutCatalog.conflict(
            for: binding,
            excluding: "/Applications/Safari.app",
            in: bindings
        ) == "/Applications/Notes.app"
    )
}

@Test("应用快捷键绑定可以持久化并恢复")
@MainActor
func appShortcutServicePersistsBinding() throws {
    let suiteName = "MenuToolsTests.AppShortcutService.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let app = LaunchableApp(
        path: "/Applications/Safari.app",
        name: "Safari",
        bundleIdentifier: "com.apple.Safari"
    )
    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let service = AppShortcutService(
        defaults: defaults,
        conflictChecker: AppShortcutNoConflictChecker(),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] }
    )

    try service.setBinding(binding, for: app)

    let restored = AppShortcutService(
        defaults: defaults,
        conflictChecker: AppShortcutNoConflictChecker(),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] }
    )
    #expect(restored.binding(for: app) == binding)
}

@Test("应用快捷键会拒绝与场景快捷键交叉冲突")
@MainActor
func appShortcutRejectsSceneConflict() throws {
    let suiteName = "MenuToolsTests.AppShortcutSceneConflict.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let binding = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcutModifier.controlOption)
    let app = LaunchableApp(
        path: "/Applications/Safari.app",
        name: "Safari",
        bundleIdentifier: "com.apple.Safari"
    )
    let service = AppShortcutService(
        defaults: defaults,
        conflictChecker: AppShortcutStubConflictChecker(source: .scene(.work)),
        sceneBindingsProvider: { [.work: binding] },
        windowBindingsProvider: { [:] }
    )

    #expect(throws: AppShortcutError.sceneConflict(.work)) {
        try service.setBinding(binding, for: app)
    }
}
