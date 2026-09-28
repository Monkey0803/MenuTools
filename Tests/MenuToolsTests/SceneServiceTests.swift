import Foundation
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

@MainActor
private final class SceneEffectsSpy: SceneSystemEffects {
    enum Failure: Error {
        case denied
    }

    var darkMode: Bool? = false
    var nightShift: Bool? = false
    var muted: Bool? = false
    var desktopIconsShown: Bool? = true
    var preventingSleep = false
    var nightShiftSetError: Error?
    private(set) var calls: [String] = []

    func isDarkModeOn() -> Bool? { darkMode }
    func setDarkMode(_ on: Bool) throws {
        calls.append("dark:\(on)")
        darkMode = on
    }

    func isNightShiftOn() -> Bool? { nightShift }
    func setNightShift(_ on: Bool) throws {
        calls.append("night:\(on)")
        if let nightShiftSetError { throw nightShiftSetError }
        nightShift = on
    }

    func isMuted() -> Bool? { muted }
    func setMuted(_ muted: Bool) throws {
        calls.append("mute:\(muted)")
        self.muted = muted
    }

    func areDesktopIconsShown() -> Bool? { desktopIconsShown }
    func setDesktopIconsShown(_ shown: Bool) {
        calls.append("desktop:\(shown)")
        desktopIconsShown = shown
    }

    func isPreventingSleep() -> Bool { preventingSleep }
    func setPreventingSleep(_ on: Bool) {
        calls.append("sleep:\(on)")
        preventingSleep = on
    }
}

@MainActor
private final class SceneFocusScriptSpy: FocusModeScriptExecuting {
    func state(using source: String) -> Bool? { false }
    func execute(_ source: String) throws {}
}

private func makeSceneDefaults(_ name: String) throws -> UserDefaults {
    let suiteName = "SceneServiceTests.\(name).\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@Test("只有可逆动作参与退出场景的回滚")
func sceneActionsDeclareReversibility() {
    // 打开的应用不该被关掉，专注模式是开关（无法可靠还原），两者都不回滚。
    #expect(!SceneAction.openFavoriteApps.isReversible)
    #expect(!SceneAction.enableFocus.isReversible)
    #expect(SceneAction.preventSleep.isReversible)
    #expect(SceneAction.hideDesktopFiles.isReversible)
    #expect(SceneAction.restoreDesktopFiles.isReversible)
    #expect(SceneAction.setDarkMode.isReversible)
    #expect(SceneAction.enableNightShift.isReversible)
    #expect(SceneAction.muteAudio.isReversible)
}

@Test("场景逐动作报告失败，不再遇错即中断")
@MainActor
func sceneApplyReportsEachFailureWithoutAborting() throws {
    let effects = SceneEffectsSpy()
    effects.nightShiftSetError = SceneEffectsSpy.Failure.denied
    let service = SceneService(effects: effects)
    let focus = FocusModeService(scriptExecutor: SceneFocusScriptSpy())
    let launcher = AppLauncherService(defaults: try makeSceneDefaults("applyReport"))

    // 夜间模式动作顺序：深色 → 夜览 → 静音 → 专注；夜览失败后静音仍应执行。
    let report = service.apply(.night, launcher: launcher, focusService: focus)

    #expect(report.failures.map(\.action) == [.enableNightShift])
    #expect(report.succeeded.contains(.setDarkMode))
    #expect(report.succeeded.contains(.muteAudio))
    #expect(effects.muted == true)
    #expect(service.activeScene == .night)
}

@Test("退出场景回滚可逆动作并释放防休眠")
@MainActor
func sceneExitReversesReversibleActions() throws {
    let effects = SceneEffectsSpy()
    effects.desktopIconsShown = true
    let service = SceneService(effects: effects)
    let focus = FocusModeService(scriptExecutor: SceneFocusScriptSpy())
    let launcher = AppLauncherService(defaults: try makeSceneDefaults("exitDemo"))

    _ = service.apply(.demo, launcher: launcher, focusService: focus)
    #expect(effects.preventingSleep)
    #expect(effects.desktopIconsShown == false)

    _ = service.exitScene()

    // 防休眠必须被释放：否则「用完忘记 → 合盖不睡、电池跑空」。
    #expect(!effects.preventingSleep)
    #expect(effects.desktopIconsShown == true)
    #expect(service.activeScene == nil)
    #expect(service.lastSnapshot == nil)
}

@Test("退出场景按设置前的值恢复，而不是一律关闭")
@MainActor
func sceneExitRestoresPreviousValues() throws {
    let effects = SceneEffectsSpy()
    effects.darkMode = true
    effects.muted = true
    effects.nightShift = true
    let service = SceneService(effects: effects)
    let focus = FocusModeService(scriptExecutor: SceneFocusScriptSpy())
    let launcher = AppLauncherService(defaults: try makeSceneDefaults("exitRestore"))

    _ = service.apply(.night, launcher: launcher, focusService: focus)
    #expect(service.lastSnapshot?.darkModeWasOn == true)
    #expect(service.lastSnapshot?.mutedWasOn == true)

    _ = service.exitScene()

    // 之前就是深色/静音，退出后应保持，而不是被强制关闭。
    #expect(effects.darkMode == true)
    #expect(effects.muted == true)
    #expect(effects.nightShift == true)
}
