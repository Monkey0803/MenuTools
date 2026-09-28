import Foundation
import Observation

enum BuiltInPluginID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case systemControls = "system-controls"
    case systemInsights = "system-insights"
    case systemResources = "system-resources"
    case systemStorage = "system-storage"
    case networkTraffic = "network-traffic"
    case clipboard
    case translation
    case appVolume = "app-volume"
    case screenshot
    case windowManagement = "window-management"
    case appLauncher = "app-launcher"
    case automation
    case finderTools = "finder-tools"
    case smoothScroll = "smooth-scroll"

    var id: String { rawValue }
}

enum BuiltInPluginCategory: String, Codable, CaseIterable, Sendable {
    case system
    case productivity
    case media
    case developer
}

enum BuiltInPluginPermission: String, Codable, CaseIterable, Hashable, Sendable {
    case accessibility
    case automation
    case bluetooth
    case notifications
    case screenRecording
    case systemAudioRecording
}

struct BuiltInPluginManifest: Identifiable, Sendable {
    let id: BuiltInPluginID
    let category: BuiltInPluginCategory
    let titleKey: String
    let descriptionKey: String
    let symbol: String
    let requiredPermissions: Set<BuiltInPluginPermission>
    let dependencies: Set<BuiltInPluginID>
    let defaultEnabled: Bool
}

@MainActor
protocol BuiltInPluginRuntime: AnyObject {
    func start() throws
    func stop()
}

@MainActor
struct BuiltInPluginRegistration {
    let manifest: BuiltInPluginManifest
    let runtime: any BuiltInPluginRuntime
}

enum BuiltInPluginRuntimeState: Equatable, Sendable {
    case stopped
    case running
    case failed(String)
}

struct BuiltInPluginConfiguration: Codable, Equatable, Sendable {
    var enabledPluginIDs: [BuiltInPluginID]
    var orderedPluginIDs: [BuiltInPluginID]

    static let defaultConfiguration = BuiltInPluginConfiguration(
        enabledPluginIDs: BuiltInPluginID.allCases,
        orderedPluginIDs: BuiltInPluginID.allCases
    )

    func validated() throws -> Self {
        if let duplicate = enabledPluginIDs.firstDuplicate {
            throw BuiltInPluginConfigurationError.duplicatePlugin(duplicate)
        }
        if let duplicate = orderedPluginIDs.firstDuplicate {
            throw BuiltInPluginConfigurationError.duplicatePlugin(duplicate)
        }
        let normalizedOrder = orderedPluginIDs
            + enabledPluginIDs.filter { !orderedPluginIDs.contains($0) }
        let enabled = Set(enabledPluginIDs)
        let normalizedEnabled = normalizedOrder.filter(enabled.contains)
        return BuiltInPluginConfiguration(
            enabledPluginIDs: normalizedEnabled,
            orderedPluginIDs: normalizedOrder
        )
    }
}

enum BuiltInPluginConfigurationError: Error, Equatable, Sendable {
    case duplicatePlugin(BuiltInPluginID)
}

private extension Array where Element: Hashable {
    var firstDuplicate: Element? {
        var seen: Set<Element> = []
        return first { !seen.insert($0).inserted }
    }
}

enum BuiltInPluginManagerError: LocalizedError, Equatable {
    case unknownPlugin(BuiltInPluginID)
    case dependencyCycle(BuiltInPluginID)
    case requiredBy(BuiltInPluginID)

    var errorDescription: String? {
        switch self {
        case .unknownPlugin(let id):
            return L("plugin.error.unknownPlugin", id.rawValue)
        case .dependencyCycle(let id):
            return L("plugin.error.dependencyCycle", id.rawValue)
        case .requiredBy(let id):
            return L("plugin.error.requiredBy", id.rawValue)
        }
    }
}

@MainActor
@Observable
final class BuiltInPluginManager {
    nonisolated static let storageKey = "plugins.state.v1"

    private struct StoredState: Codable {
        var version = 1
        var enabled: [String: Bool]
        var order: [String]
    }

    private let registrations: [BuiltInPluginID: BuiltInPluginRegistration]
    private let userDefaults: UserDefaults
    /// 注册顺序；存储缺失或损坏时用它兜底，也用于补齐存储里没有的插件。
    private let fallbackOrder: [BuiltInPluginID]
    private var states: [BuiltInPluginID: BuiltInPluginRuntimeState]

    private(set) var enabledPluginIDs: Set<BuiltInPluginID>
    private(set) var orderedPluginIDs: [BuiltInPluginID]
    private(set) var lastErrorMessage: String?

    var manifests: [BuiltInPluginManifest] {
        orderedPluginIDs.compactMap { registrations[$0]?.manifest }
    }

    var configuration: BuiltInPluginConfiguration {
        BuiltInPluginConfiguration(
            enabledPluginIDs: orderedPluginIDs.filter(enabledPluginIDs.contains),
            orderedPluginIDs: orderedPluginIDs
        )
    }

    init(
        registrations: [BuiltInPluginRegistration],
        userDefaults: UserDefaults = .standard
    ) {
        let fallbackOrder = registrations.map(\.manifest.id)
        self.fallbackOrder = fallbackOrder
        self.registrations = Dictionary(uniqueKeysWithValues: registrations.map {
            ($0.manifest.id, $0)
        })
        self.userDefaults = userDefaults
        self.states = Dictionary(uniqueKeysWithValues: fallbackOrder.map {
            ($0, .stopped)
        })
        self.orderedPluginIDs = fallbackOrder
        self.enabledPluginIDs = []
        applyStoredConfiguration()
    }

    /// 按存储内容重建顺序与启用集合；存储缺失、版本不符或损坏时回退到注册顺序与各插件默认值。
    private func applyStoredConfiguration() {
        guard let data = userDefaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(StoredState.self, from: data),
              stored.version == 1 else {
            orderedPluginIDs = fallbackOrder
            enabledPluginIDs = Set(fallbackOrder.compactMap { id in
                registrations[id]?.manifest.defaultEnabled == true ? id : nil
            })
            return
        }

        let known = Set(fallbackOrder)
        var restoredIDs: Set<BuiltInPluginID> = []
        let restoredOrder = stored.order.compactMap(BuiltInPluginID.init(rawValue:)).filter {
            known.contains($0) && restoredIDs.insert($0).inserted
        }
        orderedPluginIDs = restoredOrder + fallbackOrder.filter { !restoredOrder.contains($0) }
        enabledPluginIDs = Set(fallbackOrder.compactMap { id in
            let enabled = stored.enabled[id.rawValue] ?? registrations[id]?.manifest.defaultEnabled ?? false
            return enabled ? id : nil
        })
    }

    /// 从存储重新载入配置，并把运行时对齐到新配置。
    ///
    /// 备份导入等「外部直接改写 UserDefaults」的场景必须调用：否则内存态仍是旧值（功能中心开关、
    /// 面板入口都不变），而且下一次任意开关或排序都会用旧内存态整体回写，覆盖刚导入的配置。
    func reloadFromStorage() {
        applyStoredConfiguration()
        lastErrorMessage = nil

        // 先停掉不再启用的（逆序，与停止顺序一致）。
        for id in orderedPluginIDs.reversed() where !enabledPluginIDs.contains(id) {
            if states[id] == .running {
                registrations[id]?.runtime.stop()
            }
            states[id] = .stopped
        }
        // 再启动新启用或此前失败的；仍在运行的插件不重建，避免无谓打断。
        for id in orderedPluginIDs where enabledPluginIDs.contains(id) {
            guard states[id] != .running else { continue }
            do {
                try start(id, visiting: [])
            } catch {
                states[id] = .failed(String(describing: error))
                lastErrorMessage = error.localizedDescription
                persist()
            }
        }
    }

    func isEnabled(_ id: BuiltInPluginID) -> Bool {
        enabledPluginIDs.contains(id)
    }

    func runtimeState(for id: BuiltInPluginID) -> BuiltInPluginRuntimeState {
        states[id] ?? .stopped
    }

    func startEnabledPlugins() {
        for id in orderedPluginIDs where enabledPluginIDs.contains(id) {
            do {
                try start(id, visiting: [])
            } catch {
                states[id] = .failed(String(describing: error))
                lastErrorMessage = error.localizedDescription
                persist()
            }
        }
    }

    func stopAllPlugins() {
        for id in orderedPluginIDs.reversed() where states[id] == .running {
            registrations[id]?.runtime.stop()
            states[id] = .stopped
        }
    }

    func setEnabled(_ enabled: Bool, for id: BuiltInPluginID) throws {
        guard registrations[id] != nil else {
            throw BuiltInPluginManagerError.unknownPlugin(id)
        }
        if enabled {
            do {
                try start(id, visiting: [])
                persist()
                lastErrorMessage = nil
            } catch {
                enabledPluginIDs.remove(id)
                states[id] = .failed(String(describing: error))
                persist()
                lastErrorMessage = error.localizedDescription
                throw error
            }
        } else {
            if let dependent = enabledPluginIDs.first(where: { candidate in
                candidate != id && registrations[candidate]?.manifest.dependencies.contains(id) == true
            }) {
                throw BuiltInPluginManagerError.requiredBy(dependent)
            }
            if states[id] == .running {
                registrations[id]?.runtime.stop()
            }
            states[id] = .stopped
            enabledPluginIDs.remove(id)
            persist()
            lastErrorMessage = nil
        }
    }

    func movePlugins(fromOffsets: IndexSet, toOffset: Int) {
        orderedPluginIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    nonisolated static func configuration(from userDefaults: UserDefaults) -> BuiltInPluginConfiguration? {
        guard let data = userDefaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(StoredState.self, from: data),
              stored.version == 1 else {
            return nil
        }
        let order = stored.order.compactMap(BuiltInPluginID.init(rawValue:))
        let enabled = order.filter { stored.enabled[$0.rawValue] == true }
        return try? BuiltInPluginConfiguration(
            enabledPluginIDs: enabled,
            orderedPluginIDs: order
        ).validated()
    }

    nonisolated static func persist(
        _ configuration: BuiltInPluginConfiguration,
        to userDefaults: UserDefaults
    ) throws {
        let configuration = try configuration.validated()
        let enabled = Set(configuration.enabledPluginIDs)
        let stored = StoredState(
            enabled: Dictionary(uniqueKeysWithValues: BuiltInPluginID.allCases.map {
                ($0.rawValue, enabled.contains($0))
            }),
            order: configuration.orderedPluginIDs.map(\.rawValue)
        )
        userDefaults.set(try JSONEncoder().encode(stored), forKey: storageKey)
    }

    private func start(
        _ id: BuiltInPluginID,
        visiting: Set<BuiltInPluginID>
    ) throws {
        guard let registration = registrations[id] else {
            throw BuiltInPluginManagerError.unknownPlugin(id)
        }
        if states[id] == .running {
            enabledPluginIDs.insert(id)
            return
        }
        guard !visiting.contains(id) else {
            throw BuiltInPluginManagerError.dependencyCycle(id)
        }
        var nextVisiting = visiting
        nextVisiting.insert(id)
        for dependency in registration.manifest.dependencies {
            try start(dependency, visiting: nextVisiting)
        }
        do {
            try registration.runtime.start()
            states[id] = .running
            enabledPluginIDs.insert(id)
        } catch {
            states[id] = .failed(String(describing: error))
            enabledPluginIDs.remove(id)
            throw error
        }
    }

    private func persist() {
        let stored = StoredState(
            enabled: Dictionary(uniqueKeysWithValues: registrations.keys.map {
                ($0.rawValue, enabledPluginIDs.contains($0))
            }),
            order: orderedPluginIDs.map(\.rawValue)
        )
        if let data = try? JSONEncoder().encode(stored) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }
}
