import Foundation
import Testing
@testable import MenuTools

// MARK: - 测试替身

private actor ClipboardSyncOperationRecorder {
    private(set) var calls: [(url: URL, passphrase: String)] = []
    var count: Int { calls.count }

    func record(url: URL, passphrase: String) -> ClipboardSharedFileSyncOperation.Result {
        calls.append((url, passphrase))
        return ClipboardSharedFileSyncOperation.Result(importedHistoryCount: 1, importedSnippetCount: 2)
    }
}

private final class InMemoryPassphraseStore: ClipboardSyncPassphraseStoring, @unchecked Sendable {
    private var value: String?

    init(passphrase: String? = nil) {
        value = passphrase
    }

    func passphrase() -> String? { value }

    func save(_ passphrase: String) { value = passphrase }

    func clear() { value = nil }
}

private func makeSyncDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suite = "MenuTools-ClipboardAutoSync-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
}

// MARK: - 调度决策

@Test("同步到期判断按上次同步时间和间隔计算")
func syncScheduleDecidesDueByInterval() {
    let now = Date(timeIntervalSince1970: 10_000)

    #expect(ClipboardSyncSchedule.isDue(lastSyncAt: nil, interval: 900, now: now))
    #expect(!ClipboardSyncSchedule.isDue(lastSyncAt: now.addingTimeInterval(-899), interval: 900, now: now))
    #expect(ClipboardSyncSchedule.isDue(lastSyncAt: now.addingTimeInterval(-900), interval: 900, now: now))
    #expect(ClipboardSyncSchedule.isDue(lastSyncAt: now.addingTimeInterval(-5_000), interval: 900, now: now))
}

// MARK: - 自动同步服务

@Test("开启自动同步后按间隔触发，未到间隔不动手")
@MainActor
func autoSyncRunsOnlyWhenIntervalElapsed() async throws {
    let (defaults, suiteName) = makeSyncDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    defaults.set("/tmp/MenuTools-Clipboard.mtclipsync", forKey: ClipboardSyncSettings.filePathKey)
    let recorder = ClipboardSyncOperationRecorder()
    let service = ClipboardAutoSyncService(
        defaults: defaults,
        passphraseStore: InMemoryPassphraseStore(passphrase: "口令"),
        syncOperation: { url, passphrase in await recorder.record(url: url, passphrase: passphrase) }
    )
    service.setEnabled(true)
    service.setIntervalMinutes(15)

    let start = Date(timeIntervalSince1970: 1_000)
    await service.synchronizeIfDue(now: start)
    #expect(await recorder.count == 1)
    #expect(service.lastSyncAt == start)
    #expect(service.lastImportedHistoryCount == 1)
    #expect(service.lastImportedSnippetCount == 2)

    await service.synchronizeIfDue(now: start.addingTimeInterval(60))
    #expect(await recorder.count == 1)

    await service.synchronizeIfDue(now: start.addingTimeInterval(15 * 60))
    #expect(await recorder.count == 2)
}

@Test("关闭开关或缺少文件夹和口令时不会自动同步")
@MainActor
func autoSyncRequiresEnableAndConfiguration() async throws {
    let (defaults, suiteName) = makeSyncDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    let recorder = ClipboardSyncOperationRecorder()
    let service = ClipboardAutoSyncService(
        defaults: defaults,
        passphraseStore: InMemoryPassphraseStore(passphrase: nil),
        syncOperation: { url, passphrase in await recorder.record(url: url, passphrase: passphrase) }
    )

    let now = Date(timeIntervalSince1970: 2_000)

    // 开关未开
    await service.synchronizeIfDue(now: now)
    #expect(await recorder.count == 0)

    // 开关已开但没有文件夹：后台静默跳过，手动同步才需要给出原因
    service.setEnabled(true)
    await service.synchronizeIfDue(now: now)
    #expect(await recorder.count == 0)
    #expect(service.lastError == nil)
    #expect(!service.canAutoSync)

    _ = await service.synchronize(trigger: .manual, now: now)
    #expect(await recorder.count == 0)
    #expect(service.lastError != nil)

    // 有文件夹但没有保存口令
    service.clearLastError()
    defaults.set("/tmp/MenuTools-Clipboard.mtclipsync", forKey: ClipboardSyncSettings.filePathKey)
    service.refreshStoredPassphraseState()
    #expect(!service.canAutoSync)
    await service.synchronizeIfDue(now: now)
    #expect(await recorder.count == 0)
    #expect(service.lastError == nil)

    _ = await service.synchronize(trigger: .manual, now: now)
    #expect(await recorder.count == 0)
    #expect(service.lastError != nil)

    // 保存口令后才具备自动同步条件
    service.storePassphrase("口令")
    #expect(service.canAutoSync)
}

@Test("同步失败会记录错误且不推进上次同步时间")
@MainActor
func autoSyncRecordsFailureWithoutAdvancingTimestamp() async throws {
    let (defaults, suiteName) = makeSyncDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    defaults.set("/tmp/MenuTools-Clipboard.mtclipsync", forKey: ClipboardSyncSettings.filePathKey)
    let service = ClipboardAutoSyncService(
        defaults: defaults,
        passphraseStore: InMemoryPassphraseStore(passphrase: "口令"),
        syncOperation: { _, _ in throw ClipboardSyncTestError.failed }
    )
    service.setEnabled(true)

    let succeeded = await service.synchronize(trigger: .automatic, now: Date(timeIntervalSince1970: 3_000))

    #expect(!succeeded)
    #expect(service.lastSyncAt == nil)
    #expect(service.lastError == ClipboardSyncTestError.failed.localizedDescription)
}

@Test("自动同步配置会持久化并在新实例中恢复")
@MainActor
func autoSyncSettingsPersistAcrossInstances() async throws {
    let (defaults, suiteName) = makeSyncDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    defaults.set("/tmp/MenuTools-Clipboard.mtclipsync", forKey: ClipboardSyncSettings.filePathKey)

    let first = ClipboardAutoSyncService(
        defaults: defaults,
        passphraseStore: InMemoryPassphraseStore(passphrase: "口令"),
        syncOperation: { _, _ in ClipboardSharedFileSyncOperation.Result(importedHistoryCount: 0, importedSnippetCount: 0) }
    )
    first.setEnabled(true)
    first.setIntervalMinutes(60)
    await first.synchronize(trigger: .manual, now: Date(timeIntervalSince1970: 4_000))

    let second = ClipboardAutoSyncService(
        defaults: defaults,
        passphraseStore: InMemoryPassphraseStore(passphrase: "口令"),
        syncOperation: { _, _ in ClipboardSharedFileSyncOperation.Result(importedHistoryCount: 0, importedSnippetCount: 0) }
    )

    #expect(second.isEnabled)
    #expect(second.intervalMinutes == 60)
    #expect(second.lastSyncAt == Date(timeIntervalSince1970: 4_000))
}

@Test("保存与清除自动同步口令会更新可用状态")
@MainActor
func autoSyncPassphraseStoreUpdatesAvailability() {
    let (defaults, suiteName) = makeSyncDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    defaults.set("/tmp/MenuTools-Clipboard.mtclipsync", forKey: ClipboardSyncSettings.filePathKey)
    let store = InMemoryPassphraseStore(passphrase: nil)
    let service = ClipboardAutoSyncService(
        defaults: defaults,
        passphraseStore: store,
        syncOperation: { _, _ in ClipboardSharedFileSyncOperation.Result(importedHistoryCount: 0, importedSnippetCount: 0) }
    )

    #expect(!service.hasStoredPassphrase)
    #expect(!service.canAutoSync)

    service.storePassphrase("新口令")
    #expect(service.hasStoredPassphrase)
    #expect(store.passphrase() == "新口令")

    service.clearStoredPassphrase()
    #expect(!service.hasStoredPassphrase)
    #expect(store.passphrase() == nil)
}

private enum ClipboardSyncTestError: LocalizedError {
    case failed

    var errorDescription: String? { "同步失败" }
}
