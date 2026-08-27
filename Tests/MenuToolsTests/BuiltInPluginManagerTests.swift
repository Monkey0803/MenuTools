import Foundation
import Testing
@testable import MenuTools

@Test("首次升级时默认启用全部内置插件")
@MainActor
func builtInPluginsDefaultToEnabled() throws {
    let defaults = try makePluginDefaults("defaultEnabled")
    let runtimes = BuiltInPluginID.allCases.map { ($0, PluginRuntimeSpy()) }
    let manager = BuiltInPluginManager(
        registrations: runtimes.map {
            BuiltInPluginRegistration(
                manifest: .fixture(id: $0.0),
                runtime: $0.1
            )
        },
        userDefaults: defaults
    )

    #expect(manager.enabledPluginIDs == Set(BuiltInPluginID.allCases))
}

@Test("启动时只运行已启用插件")
@MainActor
func pluginManagerStartsOnlyEnabledPlugins() throws {
    let defaults = try makePluginDefaults("startEnabled")
    let clipboard = PluginRuntimeSpy()
    let screenshot = PluginRuntimeSpy()
    let manager = BuiltInPluginManager(
        registrations: [
            BuiltInPluginRegistration(manifest: .fixture(id: .clipboard), runtime: clipboard),
            BuiltInPluginRegistration(manifest: .fixture(id: .screenshot), runtime: screenshot)
        ],
        userDefaults: defaults
    )
    try manager.setEnabled(false, for: .screenshot)

    manager.startEnabledPlugins()

    #expect(clipboard.startCount == 1)
    #expect(screenshot.startCount == 0)
    #expect(manager.runtimeState(for: .clipboard) == .running)
    #expect(manager.runtimeState(for: .screenshot) == .stopped)
}

@Test("禁用插件会停止运行时并持久化")
@MainActor
func disablingPluginStopsAndPersists() throws {
    let defaults = try makePluginDefaults("disable")
    let runtime = PluginRuntimeSpy()
    let registration = BuiltInPluginRegistration(
        manifest: .fixture(id: .appVolume),
        runtime: runtime
    )
    let manager = BuiltInPluginManager(
        registrations: [registration],
        userDefaults: defaults
    )
    manager.startEnabledPlugins()

    try manager.setEnabled(false, for: .appVolume)

    #expect(runtime.stopCount == 1)
    #expect(!manager.isEnabled(.appVolume))

    let restored = BuiltInPluginManager(
        registrations: [
            BuiltInPluginRegistration(
                manifest: .fixture(id: .appVolume),
                runtime: PluginRuntimeSpy()
            )
        ],
        userDefaults: defaults
    )
    #expect(!restored.isEnabled(.appVolume))
}

@Test("启用插件会先启用依赖")
@MainActor
func enablingPluginStartsDependenciesFirst() throws {
    let defaults = try makePluginDefaults("dependencies")
    let events = PluginRuntimeEvents()
    let dependency = PluginRuntimeSpy(id: "dependency", events: events)
    let feature = PluginRuntimeSpy(id: "feature", events: events)
    let manager = BuiltInPluginManager(
        registrations: [
            BuiltInPluginRegistration(
                manifest: .fixture(id: .appLauncher),
                runtime: dependency
            ),
            BuiltInPluginRegistration(
                manifest: .fixture(id: .automation, dependencies: [.appLauncher]),
                runtime: feature
            )
        ],
        userDefaults: defaults
    )
    try manager.setEnabled(false, for: .automation)
    try manager.setEnabled(false, for: .appLauncher)

    try manager.setEnabled(true, for: .automation)

    #expect(events.values == ["start:dependency", "start:feature"])
    #expect(manager.isEnabled(.appLauncher))
    #expect(manager.isEnabled(.automation))
}

@Test("运行时启动失败会回滚启用状态")
@MainActor
func failedPluginStartRollsBackEnabledState() throws {
    let defaults = try makePluginDefaults("startFailure")
    let runtime = PluginRuntimeSpy(startError: PluginRuntimeSpy.Error.startFailed)
    let manager = BuiltInPluginManager(
        registrations: [
            BuiltInPluginRegistration(
                manifest: .fixture(id: .screenshot),
                runtime: runtime
            )
        ],
        userDefaults: defaults
    )
    try manager.setEnabled(false, for: .screenshot)

    #expect(throws: PluginRuntimeSpy.Error.startFailed) {
        try manager.setEnabled(true, for: .screenshot)
    }

    #expect(!manager.isEnabled(.screenshot))
    #expect(manager.runtimeState(for: .screenshot) == .failed("startFailed"))
}

@Test("启动阶段失败也会持久化禁用状态")
@MainActor
func startupFailurePersistsDisabledState() throws {
    let defaults = try makePluginDefaults("startupFailure")
    let manager = BuiltInPluginManager(
        registrations: [
            BuiltInPluginRegistration(
                manifest: .fixture(id: .screenshot),
                runtime: PluginRuntimeSpy(startError: PluginRuntimeSpy.Error.startFailed)
            )
        ],
        userDefaults: defaults
    )

    manager.startEnabledPlugins()

    let restored = BuiltInPluginManager(
        registrations: [
            BuiltInPluginRegistration(
                manifest: .fixture(id: .screenshot),
                runtime: PluginRuntimeSpy()
            )
        ],
        userDefaults: defaults
    )
    #expect(!restored.isEnabled(.screenshot))
}

@Test("损坏或未知插件配置不会隐藏现有功能")
@MainActor
func invalidPluginPreferencesFallBackSafely() throws {
    let defaults = try makePluginDefaults("invalidPreferences")
    defaults.set(Data("broken".utf8), forKey: BuiltInPluginManager.storageKey)
    let manager = BuiltInPluginManager(
        registrations: [
            BuiltInPluginRegistration(
                manifest: .fixture(id: .clipboard),
                runtime: PluginRuntimeSpy()
            )
        ],
        userDefaults: defaults
    )

    #expect(manager.isEnabled(.clipboard))
}

@Test("插件配置可以导出并恢复启用状态和顺序")
@MainActor
func pluginConfigurationRoundTrips() throws {
    let defaults = try makePluginDefaults("configurationRoundTrip")
    let registrations = [
        BuiltInPluginRegistration(manifest: .fixture(id: .clipboard), runtime: PluginRuntimeSpy()),
        BuiltInPluginRegistration(manifest: .fixture(id: .screenshot), runtime: PluginRuntimeSpy()),
        BuiltInPluginRegistration(manifest: .fixture(id: .appVolume), runtime: PluginRuntimeSpy())
    ]
    let manager = BuiltInPluginManager(registrations: registrations, userDefaults: defaults)
    try manager.setEnabled(false, for: .screenshot)
    manager.movePlugins(fromOffsets: IndexSet(integer: 2), toOffset: 0)

    let configuration = manager.configuration
    #expect(configuration.enabledPluginIDs == [.appVolume, .clipboard])
    #expect(configuration.orderedPluginIDs == [.appVolume, .clipboard, .screenshot])

    let restoredDefaults = try makePluginDefaults("configurationRestored")
    try BuiltInPluginManager.persist(configuration, to: restoredDefaults)
    let restored = BuiltInPluginManager(registrations: registrations, userDefaults: restoredDefaults)

    #expect(restored.enabledPluginIDs == [.appVolume, .clipboard])
    #expect(restored.orderedPluginIDs == [.appVolume, .clipboard, .screenshot])
}

@Test("插件配置拒绝重复和未知顺序")
func pluginConfigurationValidationRejectsInvalidValues() {
    #expect(throws: BuiltInPluginConfigurationError.duplicatePlugin(.clipboard)) {
        try BuiltInPluginConfiguration(
            enabledPluginIDs: [.clipboard],
            orderedPluginIDs: [.clipboard, .clipboard]
        ).validated()
    }
}

@Test("启用插件缺少排序项时会自动补入排序")
func pluginConfigurationAddsEnabledPluginsToOrder() throws {
    let configuration = try BuiltInPluginConfiguration(
        enabledPluginIDs: [.clipboard, .appVolume],
        orderedPluginIDs: [.clipboard]
    ).validated()

    #expect(configuration.orderedPluginIDs == [.clipboard, .appVolume])
    #expect(configuration.enabledPluginIDs == [.clipboard, .appVolume])
}

@Test("持久化顺序中的重复项不会生成重复插件")
@MainActor
func duplicateStoredOrderIsDeduplicated() throws {
    let defaults = try makePluginDefaults("duplicateStoredOrder")
    let stored: [String: Any] = [
        "version": 1,
        "enabled": ["clipboard": false, "screenshot": true],
        "order": ["clipboard", "clipboard", "screenshot"]
    ]
    defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: BuiltInPluginManager.storageKey)
    let manager = BuiltInPluginManager(
        registrations: [
            BuiltInPluginRegistration(manifest: .fixture(id: .clipboard), runtime: PluginRuntimeSpy()),
            BuiltInPluginRegistration(manifest: .fixture(id: .screenshot), runtime: PluginRuntimeSpy())
        ],
        userDefaults: defaults
    )

    #expect(manager.orderedPluginIDs == [.clipboard, .screenshot])
    #expect(manager.manifests.map(\.id) == [.clipboard, .screenshot])
}

private func makePluginDefaults(_ name: String) throws -> UserDefaults {
    let suiteName = "BuiltInPluginManagerTests.\(name).\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@MainActor
private final class PluginRuntimeEvents {
    var values: [String] = []
}

@MainActor
private final class PluginRuntimeSpy: BuiltInPluginRuntime {
    enum Error: Swift.Error {
        case startFailed
    }

    let id: String
    let events: PluginRuntimeEvents?
    let startError: Swift.Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(
        id: String = "runtime",
        events: PluginRuntimeEvents? = nil,
        startError: Swift.Error? = nil
    ) {
        self.id = id
        self.events = events
        self.startError = startError
    }

    func start() throws {
        startCount += 1
        if let startError { throw startError }
        events?.values.append("start:\(id)")
    }

    func stop() {
        stopCount += 1
        events?.values.append("stop:\(id)")
    }
}

private extension BuiltInPluginManifest {
    static func fixture(
        id: BuiltInPluginID,
        dependencies: Set<BuiltInPluginID> = []
    ) -> Self {
        BuiltInPluginManifest(
            id: id,
            category: .productivity,
            titleKey: "plugin.\(id.rawValue).title",
            descriptionKey: "plugin.\(id.rawValue).description",
            symbol: "puzzlepiece.extension",
            requiredPermissions: [],
            dependencies: dependencies,
            defaultEnabled: true
        )
    }
}
