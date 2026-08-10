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

@MainActor
@Observable
final class SceneService {
    static let shared = SceneService()

    private(set) var activeScene: ScenePreset?

    func apply(_ scene: ScenePreset) throws {
        let launcher = AppLauncherService()
        let focusService = FocusModeService()
        try apply(scene, launcher: launcher, focusService: focusService)
    }

    func apply(
        _ scene: ScenePreset,
        launcher: AppLauncherService,
        focusService: FocusModeService
    ) throws {
        for action in scene.actions {
            switch action {
            case .openFavoriteApps:
                for app in launcher.favoriteApps {
                    _ = launcher.launch(app)
                }
            case .enableFocus:
                try focusService.toggle()
            case .preventSleep:
                CaffeinateService.shared.start()
            case .hideDesktopFiles:
                SystemToggleService.setDesktopIconsShown(false)
            case .restoreDesktopFiles:
                SystemToggleService.setDesktopIconsShown(true)
            case .setDarkMode:
                try AppearanceService.setDarkMode(true)
            case .enableNightShift:
                try NightShiftService.setEnabled(true)
            case .muteAudio:
                try SystemToggleService.setMuted(true)
            }
        }
        activeScene = scene
    }
}
