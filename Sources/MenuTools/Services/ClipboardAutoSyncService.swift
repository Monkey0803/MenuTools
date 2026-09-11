import Foundation
import Observation
import Security

/// 剪贴板共享文件夹同步的持久化设置键。
enum ClipboardSyncSettings {
    static let filePathKey = "clipboard.syncFilePath"
    static let autoEnabledKey = "clipboard.sync.autoEnabled"
    static let intervalMinutesKey = "clipboard.sync.intervalMinutes"
    static let lastSyncAtKey = "clipboard.sync.lastSyncAt"

    /// 自动同步可选间隔（分钟）。
    static let intervalOptions = [5, 15, 30, 60, 240]
    static let defaultIntervalMinutes = 15
}

/// 自动同步口令的存取。
/// 自动同步需要在用户不输入口令的情况下工作，因此必须持久化；
/// 口令属于敏感数据，默认放钥匙串而不是 UserDefaults。
protocol ClipboardSyncPassphraseStoring: Sendable {
    func passphrase() -> String?
    func save(_ passphrase: String)
    func clear()
}

struct ClipboardSyncKeychainPassphraseStore: ClipboardSyncPassphraseStoring {
    private let service = "com.qoder.menutools.clipboard-sync"
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

/// 到期判断独立成纯函数，便于测试。
enum ClipboardSyncSchedule {
    static func isDue(lastSyncAt: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard let lastSyncAt else { return true }
        return now.timeIntervalSince(lastSyncAt) >= interval
    }
}

enum ClipboardSyncTrigger: Sendable, Equatable {
    case manual
    case automatic
}

/// 共享文件夹同步的实际动作：读远端、合并、写回，并把结果导入本机。
@MainActor
enum ClipboardSharedFileSyncOperation {
    struct Result: Equatable, Sendable {
        var importedHistoryCount: Int
        var importedSnippetCount: Int
    }

    static func run(
        fileURL: URL,
        passphrase: String,
        historyService: ClipboardHistoryService,
        snippetService: ClipboardSnippetService
    ) async throws -> Result {
        let local = ClipboardArchiveDocument.current(
            historyItems: historyService.items.filter(\.isPinned),
            snippetGroups: snippetService.groups,
            snippets: snippetService.snippets
        )
        let merged = try await Task.detached(priority: .utility) {
            try ClipboardSharedFileSync.synchronize(
                local: local,
                at: fileURL,
                passphrase: passphrase
            )
        }.value
        historyService.importItems(merged.historyItems)
        snippetService.replaceImported(groups: merged.snippetGroups, snippets: merged.snippets)
        return Result(
            importedHistoryCount: merged.historyItems.count,
            importedSnippetCount: merged.snippets.count
        )
    }
}

/// 剪贴板共享文件夹的自动同步：保存开关、间隔、上次同步时间和错误，
/// 并在开启时按间隔自动调用同步动作。
@MainActor
@Observable
final class ClipboardAutoSyncService {
    static let shared = ClipboardAutoSyncService()

    /// 检查周期；真正的到期判断交给 `ClipboardSyncSchedule`。
    private static let tickInterval: Duration = .seconds(30)

    private let defaults: UserDefaults
    private let passphraseStore: any ClipboardSyncPassphraseStoring
    private let syncOperation: @MainActor (URL, String) async throws -> ClipboardSharedFileSyncOperation.Result
    private var timerTask: Task<Void, Never>?

    private(set) var isEnabled: Bool
    private(set) var intervalMinutes: Int
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var lastImportedHistoryCount = 0
    private(set) var lastImportedSnippetCount = 0
    private(set) var isSyncing = false
    private(set) var hasStoredPassphrase: Bool

    var syncFileURL: URL? {
        guard let path = defaults.string(forKey: ClipboardSyncSettings.filePathKey), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// 只有开关打开、选好文件夹并且已保存口令时才允许自动同步。
    var canAutoSync: Bool {
        isEnabled && syncFileURL != nil && hasStoredPassphrase
    }

    init(
        defaults: UserDefaults = .standard,
        passphraseStore: any ClipboardSyncPassphraseStoring = ClipboardSyncKeychainPassphraseStore(),
        syncOperation: (@MainActor (URL, String) async throws -> ClipboardSharedFileSyncOperation.Result)? = nil
    ) {
        self.defaults = defaults
        self.passphraseStore = passphraseStore
        self.syncOperation = syncOperation ?? { url, passphrase in
            try await ClipboardSharedFileSyncOperation.run(
                fileURL: url,
                passphrase: passphrase,
                historyService: ClipboardHistoryService.shared,
                snippetService: ClipboardSnippetService.shared
            )
        }
        self.isEnabled = defaults.bool(forKey: ClipboardSyncSettings.autoEnabledKey)
        let storedInterval = defaults.integer(forKey: ClipboardSyncSettings.intervalMinutesKey)
        self.intervalMinutes = ClipboardSyncSettings.intervalOptions.contains(storedInterval)
            ? storedInterval
            : ClipboardSyncSettings.defaultIntervalMinutes
        self.lastSyncAt = defaults.object(forKey: ClipboardSyncSettings.lastSyncAtKey) as? Date
        self.hasStoredPassphrase = passphraseStore.passphrase() != nil
    }

    // MARK: - 设置

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: ClipboardSyncSettings.autoEnabledKey)
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func setIntervalMinutes(_ minutes: Int) {
        guard ClipboardSyncSettings.intervalOptions.contains(minutes), intervalMinutes != minutes else { return }
        intervalMinutes = minutes
        defaults.set(minutes, forKey: ClipboardSyncSettings.intervalMinutesKey)
    }

    func storePassphrase(_ passphrase: String) {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        passphraseStore.save(trimmed)
        hasStoredPassphrase = true
    }

    func clearStoredPassphrase() {
        passphraseStore.clear()
        hasStoredPassphrase = false
    }

    /// 文件夹或钥匙串状态在外部变化后同步一次可用性。
    func refreshStoredPassphraseState() {
        hasStoredPassphrase = passphraseStore.passphrase() != nil
    }

    /// 用户修好配置后清掉上一次的错误提示。
    func clearLastError() {
        lastError = nil
    }

    // MARK: - 调度

    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { @MainActor [weak self] in
            // 启动时先补一次到期检查，之后按周期轮询。
            await self?.synchronizeIfDue()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled else { return }
                await self?.synchronizeIfDue()
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// 到期才同步；未开启或缺配置时直接返回。
    func synchronizeIfDue(now: Date = Date()) async {
        guard canAutoSync else { return }
        guard ClipboardSyncSchedule.isDue(
            lastSyncAt: lastSyncAt,
            interval: TimeInterval(intervalMinutes * 60),
            now: now
        ) else {
            return
        }
        await synchronize(trigger: .automatic, now: now)
    }

    /// - Parameter passphraseOverride: 手动同步时直接用输入框里的口令，无需先保存到钥匙串。
    @discardableResult
    func synchronize(
        trigger: ClipboardSyncTrigger,
        passphrase passphraseOverride: String? = nil,
        now: Date = Date()
    ) async -> Bool {
        guard let fileURL = syncFileURL else {
            lastError = L("clipboard.sync.error.noFolder")
            return false
        }
        let passphrase = (passphraseOverride ?? passphraseStore.passphrase())?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let passphrase, !passphrase.isEmpty else {
            lastError = L("clipboard.sync.error.noPassphrase")
            return false
        }
        guard !isSyncing else { return false }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let result = try await syncOperation(fileURL, passphrase)
            lastSyncAt = now
            defaults.set(now, forKey: ClipboardSyncSettings.lastSyncAtKey)
            lastImportedHistoryCount = result.importedHistoryCount
            lastImportedSnippetCount = result.importedSnippetCount
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
