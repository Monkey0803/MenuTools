import AppKit
import Foundation
import Observation

enum SceneAction: String, CaseIterable, Equatable, Sendable {
    case openFavoriteApps
    case enableFocus
    case preventSleep
    case hideDesktopFiles
    case restoreDesktopFiles
    case setDarkMode
    case enableNightShift
    case muteAudio

    /// 是否参与「退出场景」的回滚。
    ///
    /// 打开的应用不该被关掉；专注模式是开关（无法可靠读回并还原），因此两者都不回滚。
    var isReversible: Bool {
        switch self {
        case .openFavoriteApps, .enableFocus: return false
        case .preventSleep, .hideDesktopFiles, .restoreDesktopFiles,
             .setDarkMode, .enableNightShift, .muteAudio: return true
        }
    }
}

enum ScenePreset: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case work
    case demo
    case night

    var id: String { rawValue }

    var titleKey: String { "scene.\(rawValue)" }
    var subtitleKey: String { "scene.\(rawValue).desc" }

    var symbol: String {
        switch self {
        case .work: return "briefcase.fill"
        case .demo: return "play.rectangle.fill"
        case .night: return "moon.stars.fill"
        }
    }

    var actions: [SceneAction] {
        switch self {
        case .work: return [.openFavoriteApps, .setDarkMode, .enableFocus]
        case .demo: return [.openFavoriteApps, .preventSleep, .hideDesktopFiles, .enableFocus]
        case .night: return [.setDarkMode, .enableNightShift, .muteAudio, .enableFocus]
        }
    }
}

/// 场景施加之前记录的可逆状态，供「退出场景」按原值还原。
struct SceneSnapshot: Equatable {
    var darkModeWasOn: Bool?
    var nightShiftWasOn: Bool?
    var mutedWasOn: Bool?
    var desktopIconsWereShown: Bool?
    /// 施加前是否已在防休眠；**nil 表示本次场景没有施加该动作**，退出时不应触碰。
    var wasPreventingSleep: Bool?
}

/// 场景施加结果：逐动作报告，不再「遇错即中断、只抛第一条」。
struct SceneApplyReport: Equatable {
    struct Failure: Equatable {
        var action: SceneAction
        var message: String
    }

    var succeeded: [SceneAction] = []
    var failures: [Failure] = []

    var isFullSuccess: Bool { failures.isEmpty }
}

/// 场景依赖的系统能力边界：抽出来才能逐动作报告失败，并让「退出场景」的逆向动作可回归。
@MainActor
protocol SceneSystemEffects: AnyObject {
    func isDarkModeOn() -> Bool?
    func setDarkMode(_ on: Bool) throws
    func isNightShiftOn() -> Bool?
    func setNightShift(_ on: Bool) throws
    func isMuted() -> Bool?
    func setMuted(_ muted: Bool) throws
    func areDesktopIconsShown() -> Bool?
    func setDesktopIconsShown(_ shown: Bool)
    func isPreventingSleep() -> Bool
    func setPreventingSleep(_ on: Bool)
}

/// 绑定真实系统 API 的实现。
@MainActor
final class LiveSceneSystemEffects: SceneSystemEffects {
    func isDarkModeOn() -> Bool? { AppearanceService.isDarkMode }
    func setDarkMode(_ on: Bool) throws { try AppearanceService.setDarkMode(on) }

    func isNightShiftOn() -> Bool? { NightShiftService.isEnabled }
    func setNightShift(_ on: Bool) throws { try NightShiftService.setEnabled(on) }

    func isMuted() -> Bool? { SystemToggleService.isMuted }
    func setMuted(_ muted: Bool) throws { try SystemToggleService.setMuted(muted) }

    func areDesktopIconsShown() -> Bool? { SystemToggleService.desktopIconsShown }
    func setDesktopIconsShown(_ shown: Bool) { SystemToggleService.setDesktopIconsShown(shown) }

    func isPreventingSleep() -> Bool { CaffeinateService.shared.isActive }
    func setPreventingSleep(_ on: Bool) {
        if on {
            CaffeinateService.shared.start()
        } else {
            CaffeinateService.shared.stop()
        }
    }
}

@MainActor
@Observable
final class SceneService {
    static let shared = SceneService()

    private(set) var activeScene: ScenePreset?
    /// 当前场景施加前记录的可逆状态；「退出场景」按它还原。
    private(set) var lastSnapshot: SceneSnapshot?

    private let effects: any SceneSystemEffects

    init(effects: any SceneSystemEffects = LiveSceneSystemEffects()) {
        self.effects = effects
    }

    @discardableResult
    func apply(_ scene: ScenePreset) -> SceneApplyReport {
        apply(scene, launcher: AppLauncherService(), focusService: FocusModeService())
    }

    /// 施加场景：逐个执行并记录结果，某个动作失败不会中断其余动作。
    @discardableResult
    func apply(
        _ scene: ScenePreset,
        launcher: AppLauncherService,
        focusService: FocusModeService
    ) -> SceneApplyReport {
        var report = SceneApplyReport()
        var snapshot = SceneSnapshot()
        for action in scene.actions {
            do {
                try perform(action, snapshot: &snapshot, launcher: launcher, focusService: focusService)
                report.succeeded.append(action)
            } catch {
                report.failures.append(.init(action: action, message: error.localizedDescription))
            }
        }
        lastSnapshot = snapshot
        activeScene = scene
        return report
    }

    /// 退出当前场景：只回滚可逆动作，并按施加前的值还原，而不是一律关掉。
    @discardableResult
    func exitScene() -> SceneApplyReport {
        var report = SceneApplyReport()
        let snapshot = lastSnapshot
        activeScene = nil
        lastSnapshot = nil
        guard let snapshot else { return report }

        // 防休眠必须释放：否则「用完忘记 → 合盖不睡、电池跑空」。
        // 还原为「施加前的值」，而不是无条件关闭：用户本来就开着防休眠时要保持。
        if let wasPreventingSleep = snapshot.wasPreventingSleep {
            effects.setPreventingSleep(wasPreventingSleep)
            report.succeeded.append(.preventSleep)
        }
        if let shown = snapshot.desktopIconsWereShown {
            effects.setDesktopIconsShown(shown)
            report.succeeded.append(.hideDesktopFiles)
        }
        restore(.setDarkMode, value: snapshot.darkModeWasOn, into: &report) { try effects.setDarkMode($0) }
        restore(.enableNightShift, value: snapshot.nightShiftWasOn, into: &report) { try effects.setNightShift($0) }
        restore(.muteAudio, value: snapshot.mutedWasOn, into: &report) { try effects.setMuted($0) }
        return report
    }

    private func restore(
        _ action: SceneAction,
        value: Bool?,
        into report: inout SceneApplyReport,
        set: (Bool) throws -> Void
    ) {
        guard let value else { return }
        do {
            try set(value)
            report.succeeded.append(action)
        } catch {
            report.failures.append(.init(action: action, message: error.localizedDescription))
        }
    }

    private func perform(
        _ action: SceneAction,
        snapshot: inout SceneSnapshot,
        launcher: AppLauncherService,
        focusService: FocusModeService
    ) throws {
        switch action {
        case .openFavoriteApps:
            for app in launcher.favoriteApps {
                _ = launcher.launch(app)
            }
        case .enableFocus:
            try focusService.toggle()
        case .preventSleep:
            snapshot.wasPreventingSleep = effects.isPreventingSleep()
            effects.setPreventingSleep(true)
        case .hideDesktopFiles:
            snapshot.desktopIconsWereShown = effects.areDesktopIconsShown()
            effects.setDesktopIconsShown(false)
        case .restoreDesktopFiles:
            snapshot.desktopIconsWereShown = effects.areDesktopIconsShown()
            effects.setDesktopIconsShown(true)
        case .setDarkMode:
            snapshot.darkModeWasOn = effects.isDarkModeOn()
            try effects.setDarkMode(true)
        case .enableNightShift:
            snapshot.nightShiftWasOn = effects.isNightShiftOn()
            try effects.setNightShift(true)
        case .muteAudio:
            snapshot.mutedWasOn = effects.isMuted()
            try effects.setMuted(true)
        }
    }
}
