import AppKit
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

/// 按预先给定的结果序列返回成功/失败，用于验证退避行为。
private actor ClipboardSyncOperationStub {
    enum Outcome {
        case success
        case failure
    }

    private var outcomes: [Outcome]
    private(set) var callCount = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func perform() throws -> ClipboardSharedFileSyncOperation.Result {
        callCount += 1
        let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
        switch outcome {
        case .success:
            return ClipboardSharedFileSyncOperation.Result(importedHistoryCount: 1, importedSnippetCount: 0)
        case .failure:
            throw ClipboardSyncTestError.failed
        }
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

@Test("失败退避按 1/2/5/15 分钟后保持 15 分钟")
func syncScheduleBacksOffAfterFailures() {
    #expect(ClipboardSyncSchedule.backoff(afterFailures: 0) == 0)
    #expect(ClipboardSyncSchedule.backoff(afterFailures: 1) == 60)
    #expect(ClipboardSyncSchedule.backoff(afterFailures: 2) == 120)
    #expect(ClipboardSyncSchedule.backoff(afterFailures: 3) == 300)
    #expect(ClipboardSyncSchedule.backoff(afterFailures: 4) == 900)
    #expect(ClipboardSyncSchedule.backoff(afterFailures: 9) == 900)
}

@Test("同步失败后按退避跳过后续轮询，成功后重置")
@MainActor
func autoSyncBacksOffAfterFailure() async throws {
    let (defaults, suiteName) = makeSyncDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    defaults.set("/tmp/MenuTools-Clipboard.mtclipsync", forKey: ClipboardSyncSettings.filePathKey)
    // 前两次失败，第三次成功。
    let stub = ClipboardSyncOperationStub(outcomes: [.failure, .failure, .success])
    let service = ClipboardAutoSyncService(
        defaults: defaults,
        passphraseStore: InMemoryPassphraseStore(passphrase: "口令"),
        syncOperation: { _, _ in try await stub.perform() }
    )
    service.setEnabled(true)
    service.setIntervalMinutes(5)

    let start = Date(timeIntervalSince1970: 10_000)
    await service.synchronizeIfDue(now: start)
    #expect(await stub.callCount == 1)
    #expect(service.consecutiveFailures == 1)
    #expect(service.nextRetryAt == start.addingTimeInterval(60))

    // 30 秒后仍在退避窗口内，不再打
    await service.synchronizeIfDue(now: start.addingTimeInterval(30))
    #expect(await stub.callCount == 1)

    // 退避到期后重试，失败次数累加，退避变成 2 分钟
    await service.synchronizeIfDue(now: start.addingTimeInterval(60))
    #expect(await stub.callCount == 2)
    #expect(service.consecutiveFailures == 2)
    #expect(service.nextRetryAt == start.addingTimeInterval(60 + 120))

    // 第三次成功：失败计数与退避都清空
    await service.synchronizeIfDue(now: start.addingTimeInterval(60 + 120))
    #expect(await stub.callCount == 3)
    #expect(service.consecutiveFailures == 0)
    #expect(service.nextRetryAt == nil)
    #expect(service.lastError == nil)
}

@MainActor
private final class ClipboardSyncTriggerStub: ClipboardSyncTriggerObserving {
    private(set) var isRunning = false
    private var handler: (@MainActor () async -> Void)?

    func start(handler: @escaping @MainActor () async -> Void) {
        isRunning = true
        self.handler = handler
    }

    func stop() {
        isRunning = false
        handler = nil
    }

    func fire() async {
        await handler?()
    }
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


@Test("服务启动会挂上系统事件触发器，停止时摘掉")
@MainActor
func autoSyncArmsSystemTriggers() {
    let (defaults, suiteName) = makeSyncDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    let triggers = ClipboardSyncTriggerStub()
    let service = ClipboardAutoSyncService(
        defaults: defaults,
        passphraseStore: InMemoryPassphraseStore(passphrase: "口令"),
        syncOperation: { _, _ in ClipboardSharedFileSyncOperation.Result(importedHistoryCount: 0, importedSnippetCount: 0) },
        triggers: triggers
    )

    service.start()
    #expect(triggers.isRunning)

    service.stop()
    #expect(!triggers.isRunning)
}

@Test("系统触发只在到期时补同步")
@MainActor
func autoSyncSystemTriggerRespectsDueCheck() async throws {
    let (defaults, suiteName) = makeSyncDefaults()
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    defaults.set("/tmp/MenuTools-Clipboard.mtclipsync", forKey: ClipboardSyncSettings.filePathKey)
    let recorder = ClipboardSyncOperationRecorder()
    let service = ClipboardAutoSyncService(
        defaults: defaults,
        passphraseStore: InMemoryPassphraseStore(passphrase: "口令"),
        syncOperation: { url, passphrase in await recorder.record(url: url, passphrase: passphrase) },
        triggers: ClipboardSyncTriggerStub()
    )
    service.setEnabled(true)
    service.setIntervalMinutes(15)

    // 唤醒时到期 → 补一次
    await service.handleSystemTrigger(now: Date(timeIntervalSince1970: 1_000))
    #expect(await recorder.count == 1)

    // 刚同步完就唤醒 → 未到期，不动手
    await service.handleSystemTrigger(now: Date(timeIntervalSince1970: 1_060))
    #expect(await recorder.count == 1)
}

@Test("系统唤醒通知会转发成补同步回调")
@MainActor
func systemTriggerForwardsWakeNotification() async {
    let triggers = ClipboardSystemSyncTriggers()
    var fired = 0
    triggers.start { fired += 1 }

    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    for _ in 0 ..< 50 where fired == 0 {
        try? await Task.sleep(for: .milliseconds(20))
    }
    triggers.stop()

    #expect(fired == 1)
}
