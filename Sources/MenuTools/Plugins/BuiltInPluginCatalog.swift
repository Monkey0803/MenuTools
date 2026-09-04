import Foundation

@MainActor
private final class ClosureBuiltInPluginRuntime: BuiltInPluginRuntime {
    private let startAction: @MainActor () throws -> Void
    private let stopAction: @MainActor () -> Void

    init(
        start: @escaping @MainActor () throws -> Void = {},
        stop: @escaping @MainActor () -> Void = {}
    ) {
        startAction = start
        stopAction = stop
    }

    func start() throws {
        try startAction()
    }

    func stop() {
        stopAction()
    }
}

@MainActor
enum BuiltInPluginCatalog {
    static func makeManager(userDefaults: UserDefaults = .standard) -> BuiltInPluginManager {
        BuiltInPluginManager(registrations: registrations(), userDefaults: userDefaults)
    }

    static func registrations() -> [BuiltInPluginRegistration] {
        [
            registration(
                id: .systemControls,
                category: .system,
                symbol: "switch.2",
                permissions: [.automation],
                stop: { CaffeinateService.shared.stop() }
            ),
            registration(
                id: .systemInsights,
                category: .system,
                symbol: "gauge.with.dots.needle.67percent",
                permissions: [.bluetooth],
                stop: { BLEBatteryMonitor.shared.stop() }
            ),
            registration(
                id: .networkTraffic,
                category: .system,
                symbol: "arrow.up.arrow.down.circle",
                start: {
                    NetworkStatusService.shared.startMonitoring()
                    NetworkTrafficService.shared.start()
                },
                stop: {
                    NetworkTrafficService.shared.stop()
                    NetworkStatusService.shared.stopMonitoring()
                }
            ),
            registration(
                id: .clipboard,
                category: .productivity,
                symbol: "clipboard",
                start: {
                    ClipboardHistoryService.shared.startMonitoring()
                    ClipboardShortcutService.shared.start()
                },
                stop: {
                    ClipboardShortcutService.shared.stop()
                    ClipboardHistoryService.shared.stopMonitoring()
                }
            ),
            registration(
                id: .translation,
                category: .productivity,
                symbol: "character.bubble",
                permissions: [.accessibility],
                start: { TranslationShortcutService.shared.start() },
                stop: {
                    TranslationShortcutService.shared.stop()
                    TranslationWindowController.shared.close()
                }
            ),
            registration(
                id: .appVolume,
                category: .media,
                symbol: "speaker.wave.2.bubble",
                permissions: [.systemAudioRecording, .accessibility],
                start: {
                    AppVolumeService.shared.start()
                    AppVolumeShortcutService.shared.start()
                },
                stop: {
                    AppVolumeShortcutService.shared.stop()
                    AppVolumeService.shared.stop()
                }
            ),
            registration(
                id: .screenshot,
                category: .productivity,
                symbol: "camera.viewfinder",
                permissions: [.screenRecording, .accessibility],
                start: {
                    ScreenshotHistoryStore.shared.pruneMissingFiles()
                    ScreenshotShortcutService.shared.start()
                    ScreenshotRegionOCRService.shared.start()
                },
                stop: {
                    ScreenshotShortcutService.shared.stop()
                    ScreenshotRegionOCRService.shared.stop()
                    ScreenshotService.shared.cancelLongCapture()
                    ScreenshotService.shared.cancelEditing()
                }
            ),
            registration(
                id: .windowManagement,
                category: .productivity,
                symbol: "macwindow.on.rectangle",
                permissions: [.accessibility],
                start: {
                    WindowShortcutService.shared.start()
                    WindowManagementService.shared.start()
                },
                stop: {
                    WindowShortcutService.shared.stop()
                    WindowManagementService.shared.stop()
                }
            ),
            registration(
                id: .appLauncher,
                category: .productivity,
                symbol: "app.badge",
                permissions: [.accessibility],
                start: { AppShortcutService.shared.start() },
                stop: { AppShortcutService.shared.stop() }
            ),
            registration(
                id: .automation,
                category: .productivity,
                symbol: "wand.and.stars",
                permissions: [.accessibility, .automation],
                start: { GlobalShortcutService.shared.start() },
                stop: { GlobalShortcutService.shared.stop() }
            ),
            registration(
                id: .finderTools,
                category: .productivity,
                symbol: "contextualmenu.and.cursorarrow",
                permissions: [.automation],
                start: { RightClickCommandHandler.activate() },
                stop: { RightClickCommandHandler.deactivate() }
            ),
            registration(
                id: .smoothScroll,
                category: .productivity,
                symbol: "computermouse",
                permissions: [.accessibility],
                start: { SmoothScrollEngine.shared.activateIfEnabled() },
                stop: { SmoothScrollEngine.shared.stop() }
            )
        ]
    }

    private static func registration(
        id: BuiltInPluginID,
        category: BuiltInPluginCategory,
        symbol: String,
        permissions: Set<BuiltInPluginPermission> = [],
        dependencies: Set<BuiltInPluginID> = [],
        start: @escaping @MainActor () throws -> Void = {},
        stop: @escaping @MainActor () -> Void = {}
    ) -> BuiltInPluginRegistration {
        BuiltInPluginRegistration(
            manifest: BuiltInPluginManifest(
                id: id,
                category: category,
                titleKey: "plugin.\(id.rawValue).title",
                descriptionKey: "plugin.\(id.rawValue).description",
                symbol: symbol,
                requiredPermissions: permissions,
                dependencies: dependencies,
                defaultEnabled: true
            ),
            runtime: ClosureBuiltInPluginRuntime(start: start, stop: stop)
        )
    }
}

@MainActor
extension BuiltInPluginManager {
    static let shared = BuiltInPluginCatalog.makeManager()
}
