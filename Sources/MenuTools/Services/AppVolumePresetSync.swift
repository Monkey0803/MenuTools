import AppKit
import Foundation
import Security

/// 音量预设共享文件的内容：预设、自动化规则、自定义 EQ 库，以及删除墓碑。
///
/// 删除必须靠墓碑传播：否则一端删掉的预设会被另一端的旧数据"复活"。
struct AppVolumePresetSyncDocument: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    /// 写入该文件的设备名，便于冲突时辨认来源。
    var deviceName: String
    var updatedAt: Date
    var presets: [AppVolumePreset]
    var automationRules: [AppVolumeAutomationRule]
    var equalizerPresets: [AppVolumeCustomEqualizer]
    /// 已删除预设：UUID 字符串 → 删除时间。
    var presetTombstones: [String: Date]
    /// 已删除自定义 EQ：UUID 字符串 → 删除时间。
    var equalizerTombstones: [String: Date]

    static func current(
        deviceName: String,
        presets: [AppVolumePreset],
        automationRules: [AppVolumeAutomationRule],
        equalizerPresets: [AppVolumeCustomEqualizer],
        presetTombstones: [String: Date] = [:],
        equalizerTombstones: [String: Date] = [:],
        updatedAt: Date = Date()
    ) -> Self {
        Self(
            formatVersion: currentFormatVersion,
            deviceName: deviceName,
            updatedAt: updatedAt,
            presets: presets,
            automationRules: automationRules,
            equalizerPresets: equalizerPresets,
            presetTombstones: presetTombstones,
            equalizerTombstones: equalizerTombstones
        )
    }

    func validated() throws -> Self {
        guard formatVersion == Self.currentFormatVersion else {
            throw AppVolumePresetSyncError.unsupportedVersion
        }
        return self
    }

    /// 合并后的共享文件内容（去掉已被墓碑压掉的条目）。
    func resolved() -> Self {
        var copy = self
        copy.presets = AppVolumePresetSyncMerge.visiblePresets(presets, tombstones: presetTombstones)
        copy.equalizerPresets = AppVolumePresetSyncMerge.visibleEqualizers(
            equalizerPresets,
            tombstones: equalizerTombstones
        )
        // 规则引用的预设若已被删除，规则本身保留但不会再命中（求值时已有保护）。
        return copy
    }
}

enum AppVolumePresetSyncError: Error, Equatable, LocalizedError {
    case unsupportedVersion
    case conflictingWrites(conflictURL: URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return L("volume.presetSync.error.unsupportedVersion")
        case let .conflictingWrites(conflictURL):
            return L("sync.error.conflict", conflictURL.lastPathComponent)
        }
    }
}

/// 预设同步的合并策略：同一 ID 按状态时间戳取新的，删除用墓碑传播。
enum AppVolumePresetSyncMerge {
    /// 墓碑保留 30 天，与剪贴板的删除保留策略一致。
    static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60

    static func pruned(
        _ tombstones: [UUID: Date],
        now: Date = Date(),
        retention: TimeInterval = tombstoneRetention
    ) -> [UUID: Date] {
        tombstones.filter { now.timeIntervalSince($0.value) < retention }
    }

    /// 条目状态时间戳：优先用更新过的时间。
    static func stateTimestamp(_ preset: AppVolumePreset) -> Date {
        preset.updatedAt ?? preset.createdAt
    }

    static func stateTimestamp(_ equalizer: AppVolumeCustomEqualizer) -> Date {
        equalizer.updatedAt ?? equalizer.createdAt
    }

    /// 墓碑是否压掉了该条目：删除时间不早于条目状态时间才算删除。
    static func isDeleted(stateTimestamp: Date, tombstones: [String: Date], id: UUID) -> Bool {
        guard let deletedAt = tombstones[id.uuidString] else { return false }
        return deletedAt >= stateTimestamp
    }

    static func visiblePresets(
        _ presets: [AppVolumePreset],
        tombstones: [String: Date]
    ) -> [AppVolumePreset] {
        presets
            .filter { !isDeleted(stateTimestamp: stateTimestamp($0), tombstones: tombstones, id: $0.id) }
            .sorted { stateTimestamp($0) > stateTimestamp($1) }
    }

    static func visibleEqualizers(
        _ equalizers: [AppVolumeCustomEqualizer],
        tombstones: [String: Date]
    ) -> [AppVolumeCustomEqualizer] {
        equalizers
            .filter { !isDeleted(stateTimestamp: stateTimestamp($0), tombstones: tombstones, id: $0.id) }
            .sorted { stateTimestamp($0) > stateTimestamp($1) }
    }

    /// 墓碑合并：同一 ID 取删除时间较晚的一方。
    static func mergeTombstones(
        local: [String: Date],
        remote: [String: Date]
    ) -> [String: Date] {
        var merged = local
        for (id, deletedAt) in remote {
            if let existing = merged[id] {
                merged[id] = max(existing, deletedAt)
            } else {
                merged[id] = deletedAt
            }
        }
        return merged
    }

    static func merge(
        local: AppVolumePresetSyncDocument,
        remote: AppVolumePresetSyncDocument,
        now: Date = Date()
    ) -> AppVolumePresetSyncDocument {
        let presetTombstones = mergeTombstones(local: local.presetTombstones, remote: remote.presetTombstones)
        let equalizerTombstones = mergeTombstones(
            local: local.equalizerTombstones,
            remote: remote.equalizerTombstones
        )

        let presets = visiblePresets(
            newerWins(local.presets, remote.presets, timestamp: stateTimestamp),
            tombstones: presetTombstones
        )
        let equalizers = visibleEqualizers(
            newerWins(local.equalizerPresets, remote.equalizerPresets, timestamp: stateTimestamp),
            tombstones: equalizerTombstones
        )

        // 自动化规则没有时间戳：同 ID 保留本机，远端独有的补进来。
        var rules = local.automationRules
        let localRuleIDs = Set(rules.map(\.id))
        rules.append(contentsOf: remote.automationRules.filter { !localRuleIDs.contains($0.id) })

        return AppVolumePresetSyncDocument(
            formatVersion: AppVolumePresetSyncDocument.currentFormatVersion,
            deviceName: local.deviceName,
            updatedAt: max(local.updatedAt, remote.updatedAt, now),
            presets: presets,
            automationRules: rules,
            equalizerPresets: equalizers,
            presetTombstones: presetTombstones,
            equalizerTombstones: equalizerTombstones
        )
    }

    /// 同一 ID 保留状态时间戳更新的一方；时间相同保留本机。
    private static func newerWins<T: Identifiable>(
        _ local: [T],
        _ remote: [T],
        timestamp: (T) -> Date
    ) -> [T] where T.ID == UUID {
        var byID: [UUID: T] = [:]
        for item in remote {
            byID[item.id] = item
        }
        for item in local {
            if let existing = byID[item.id] {
                byID[item.id] = timestamp(item) >= timestamp(existing) ? item : existing
            } else {
                byID[item.id] = item
            }
        }
        return Array(byID.values)
    }
}

extension AppVolumePresetSyncDocument: SharedFileSyncDocument {
    static let magic = "MTVOL001"

    static var emptySharedDocument: AppVolumePresetSyncDocument {
        current(deviceName: "", presets: [], automationRules: [], equalizerPresets: [])
    }

    static func decryptShared(_ data: Data, passphrase: String) throws -> AppVolumePresetSyncDocument {
        try EncryptedArchiveEnvelope.open(
            AppVolumePresetSyncDocument.self,
            from: data,
            passphrase: passphrase,
            magic: magic
        )
        .validated()
    }

    func encryptedShared(passphrase: String) throws -> Data {
        try EncryptedArchiveEnvelope.seal(self, passphrase: passphrase, magic: Self.magic)
    }

    func mergedShared(with remote: AppVolumePresetSyncDocument, now: Date) -> AppVolumePresetSyncDocument {
        AppVolumePresetSyncMerge.merge(local: self, remote: remote, now: now)
    }
}
/// 音量预设共享文件夹同步的设置键。
enum AppVolumePresetSyncSettings {
    static let filePathKey = "appVolume.presetSync.filePath"
    static let autoEnabledKey = "appVolume.presetSync.autoEnabled"
    static let intervalMinutesKey = "appVolume.presetSync.intervalMinutes"
    static let lastSyncAtKey = "appVolume.presetSync.lastSyncAt"

    /// 自动同步可选间隔（分钟）。
    static let intervalOptions = [5, 15, 30, 60, 240]
    static let defaultIntervalMinutes = 30
    /// 共享目录里的固定文件名。
    static let fileName = "MenuTools-VolumePresets.mtvolsync"
}

/// 自动同步口令的存取：与剪贴板分开存，避免两个同步共用口令。
protocol AppVolumePresetSyncPassphraseStoring: Sendable {
    func passphrase() -> String?
    func save(_ passphrase: String)
    func clear()
}

struct AppVolumePresetSyncKeychainStore: AppVolumePresetSyncPassphraseStoring {
    private let service = "com.qoder.menutools.volume-preset-sync"
    private let account = "sync-passphrase"

    func passphrase() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    func save(_ passphrase: String) {
        clear()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(passphrase.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 把预设（含自动化规则与自定义 EQ）同步到共享目录里的加密文件。
///
/// 与剪贴板同步共用 `SharedFileSync`：读远端 → 合并 → 写回，写前复核文件指纹，
/// 持续争用时写冲突副本。
@MainActor
@Observable
final class AppVolumePresetSyncService {
    static let shared = AppVolumePresetSyncService()

    private let userDefaults: UserDefaults
    private let appVolume: AppVolumeService
    private let passphraseStore: any AppVolumePresetSyncPassphraseStoring
    private let fileStore: any SharedFileStoring
    private let now: () -> Date

    private(set) var isEnabled: Bool
    private(set) var fileURL: URL?
    private(set) var intervalMinutes: Int
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false
    private(set) var hasStoredPassphrase: Bool

    private var autoSyncTimer: Timer?

    init(
        userDefaults: UserDefaults = .standard,
        appVolume: AppVolumeService = .shared,
        passphraseStore: any AppVolumePresetSyncPassphraseStoring = AppVolumePresetSyncKeychainStore(),
        fileStore: any SharedFileStoring = SharedFileStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.appVolume = appVolume
        self.passphraseStore = passphraseStore
        self.fileStore = fileStore
        self.now = now
        isEnabled = userDefaults.bool(forKey: AppVolumePresetSyncSettings.autoEnabledKey)
        let storedPath = userDefaults.string(forKey: AppVolumePresetSyncSettings.filePathKey)
        fileURL = storedPath.map { URL(fileURLWithPath: $0) }
        let storedInterval = userDefaults.integer(forKey: AppVolumePresetSyncSettings.intervalMinutesKey)
        intervalMinutes = AppVolumePresetSyncSettings.intervalOptions.contains(storedInterval)
            ? storedInterval
            : AppVolumePresetSyncSettings.defaultIntervalMinutes
        let storedSyncAt = userDefaults.double(forKey: AppVolumePresetSyncSettings.lastSyncAtKey)
        lastSyncedAt = storedSyncAt > 0 ? Date(timeIntervalSince1970: storedSyncAt) : nil
        hasStoredPassphrase = passphraseStore.passphrase() != nil
    }

    var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    var conflictCopies: [URL] {
        fileURL.map { SharedFileSync.conflictCopies(for: $0) } ?? []
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            guard fileURL != nil else {
                lastError = L("volume.presetSync.error.noFolder")
                return false
            }
            guard hasStoredPassphrase else {
                lastError = L("volume.presetSync.error.noPassphrase")
                return false
            }
        }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: AppVolumePresetSyncSettings.autoEnabledKey)
        lastError = nil
        updateTimer()
        return true
    }

    func setFileURL(_ url: URL?) {
        fileURL = url
        if let url {
            userDefaults.set(url.path, forKey: AppVolumePresetSyncSettings.filePathKey)
        } else {
            userDefaults.removeObject(forKey: AppVolumePresetSyncSettings.filePathKey)
        }
        updateTimer()
    }

    func setIntervalMinutes(_ minutes: Int) {
        let value = AppVolumePresetSyncSettings.intervalOptions.contains(minutes)
            ? minutes
            : AppVolumePresetSyncSettings.defaultIntervalMinutes
        intervalMinutes = value
        userDefaults.set(value, forKey: AppVolumePresetSyncSettings.intervalMinutesKey)
        updateTimer()
    }

    func storePassphrase(_ passphrase: String) {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        passphraseStore.save(trimmed)
        hasStoredPassphrase = true
        updateTimer()
    }

    func clearPassphrase() {
        passphraseStore.clear()
        hasStoredPassphrase = false
        updateTimer()
    }

    func storedPassphrase() -> String? {
        passphraseStore.passphrase()
    }

    /// 同步一次；返回是否成功。失败原因放在 `lastError`。
    @discardableResult
    func synchronize(passphrase: String) -> Bool {
        guard let url = fileURL else {
            lastError = L("volume.presetSync.error.noFolder")
            return false
        }
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = L("volume.presetSync.error.noPassphrase")
            return false
        }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let timestamp = now()
            let local = appVolume.presetSyncDocument(deviceName: deviceName, now: timestamp)
            let merged = try SharedFileSync.synchronize(
                local: local,
                at: url,
                passphrase: trimmed,
                store: fileStore,
                now: timestamp
            )
            appVolume.applyPresetSyncDocument(merged)
            lastSyncedAt = timestamp
            userDefaults.set(timestamp.timeIntervalSince1970, forKey: AppVolumePresetSyncSettings.lastSyncAtKey)
            lastError = nil
            return true
        } catch let error as SharedFileSyncError {
            switch error {
            case let .conflictingWrites(conflictURL):
                lastError = AppVolumePresetSyncError.conflictingWrites(conflictURL: conflictURL).errorDescription
            }
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func clearLastError() {
        lastError = nil
    }

    private func updateTimer() {
        guard isEnabled, let passphrase = passphraseStore.passphrase() else {
            autoSyncTimer?.invalidate()
            autoSyncTimer = nil
            return
        }
        autoSyncTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(intervalMinutes) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.synchronize(passphrase: passphrase)
            }
        }
        autoSyncTimer = timer
    }
}
