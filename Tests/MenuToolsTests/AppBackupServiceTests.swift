import Foundation
import Testing
@testable import MenuTools

@Test("备份文档只读取明确允许的 UserDefaults 配置")
func makeDocumentReadsOnlyAllowlistedSettings() throws {
    let defaults = UserDefaults(suiteName: "AppBackupServiceTests.allowlist")!
    defaults.removePersistentDomain(forName: "AppBackupServiceTests.allowlist")
    defaults.set("terminal.fill", forKey: SettingsKey.menuBarIcon)
    defaults.set(true, forKey: SettingsKey.menuBarShowTitle)
    defaults.set(true, forKey: SettingsKey.togglesShowTitle)
    defaults.set("com.googlecode.iterm2", forKey: SettingsKey.preferredTerminal)
    defaults.set(false, forKey: SettingsKey.autoCheckUpdate)
    defaults.set("zh-Hans", forKey: SettingsKey.appLanguage)
    defaults.set(true, forKey: SettingsKey.scrollEnabled)
    defaults.set(false, forKey: SettingsKey.scrollSmoothV)
    defaults.set(true, forKey: SettingsKey.scrollSmoothH)
    defaults.set(true, forKey: SettingsKey.scrollInvertV)
    defaults.set(false, forKey: SettingsKey.scrollInvertH)
    defaults.set(1.75, forKey: SettingsKey.scrollGain)
    defaults.set(0.5, forKey: SettingsKey.scrollDuration)
    defaults.set(16.0, forKey: SettingsKey.scrollMinStep)
    defaults.set(false, forKey: SettingsKey.scrollTouchpad)
    defaults.set(1 << 20, forKey: SettingsKey.scrollAccelKey)
    defaults.set(1 << 17, forKey: SettingsKey.scrollShiftKey)
    defaults.set(0, forKey: SettingsKey.scrollDisableKey)
    defaults.set("https://example.invalid/test-feed", forKey: "updateFeedURL")

    let document = AppBackupService.makeDocument(
        userDefaults: defaults,
        rightClick: RightClickConfig(enabled: [RightClickItem.newFolder.rawValue: false]),
        appVersion: "1.0.1",
        createdAt: Date(timeIntervalSince1970: 100)
    )

    #expect(document.settings.menuBarIcon == "terminal.fill")
    #expect(document.settings.preferredTerminal == "com.googlecode.iterm2")
    #expect(document.settings.scrollGain == 1.75)
    #expect(document.rightClick == RightClickConfig(enabled: [RightClickItem.newFolder.rawValue: false]))

    let encoded = try AppBackupService.encode(document)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["updateFeedURL"] == nil)
}

@Test("备份文档可以通过服务编码和解码")
func serviceEncodesAndDecodesDocument() throws {
    let document = AppBackupDocument.current(
        settings: .serviceFixture,
        rightClick: RightClickConfig(enabled: [RightClickItem.copyFileURL.rawValue: false]),
        appVersion: "1.0.1",
        createdAt: Date(timeIntervalSince1970: 200)
    )

    let data = try AppBackupService.encode(document)
    let decoded = try AppBackupService.decode(data)

    #expect(decoded == document)
}

@Test("合法备份恢复 UserDefaults 和右键配置")
func restoreWritesAllAllowlistedSettings() throws {
    let defaults = try makeDefaults(named: "success")
    let store = InMemoryRightClickStore(
        config: RightClickConfig(enabled: [RightClickItem.newFolder.rawValue: true])
    )
    let document = AppBackupDocument.current(
        settings: .serviceFixture,
        rightClick: RightClickConfig(enabled: [RightClickItem.copyAbsolutePath.rawValue: false]),
        appVersion: "1.0.1",
        createdAt: Date(timeIntervalSince1970: 300)
    )

    try AppBackupService.restore(document, userDefaults: defaults, rightClickStore: store)

    #expect(defaults.string(forKey: SettingsKey.menuBarIcon) == "terminal.fill")
    #expect(defaults.bool(forKey: SettingsKey.menuBarShowTitle))
    #expect(defaults.double(forKey: SettingsKey.scrollGain) == 1.5)
    #expect(defaults.integer(forKey: SettingsKey.scrollAccelKey) == 1 << 20)
    #expect(store.config == document.rightClick)
}

@Test("非法文档校验失败且不会修改现有配置")
func invalidDocumentDoesNotMutateConfiguration() throws {
    let defaults = try makeDefaults(named: "invalid")
    let beforeDefaults = defaults.dictionaryRepresentation()
    let store = InMemoryRightClickStore(config: .default)
    let beforeRightClick = store.config
    var invalid = AppBackupDocument.current(
        settings: .serviceFixture,
        rightClick: RightClickConfig(enabled: [:]),
        appVersion: "1.0.1",
        createdAt: Date()
    )
    invalid.settings.scrollGain = 100

    #expect(throws: AppBackupValidationError.invalidGain(100)) {
        try AppBackupService.restore(invalid, userDefaults: defaults, rightClickStore: store)
    }
    #expect((defaults.dictionaryRepresentation() as NSDictionary).isEqual(to: beforeDefaults))
    #expect(store.config == beforeRightClick)
    #expect(store.replaceCallCount == 0)
}

@Test("非法枚举值校验失败且不会修改现有配置")
func invalidAllowlistedValueDoesNotMutateConfiguration() throws {
    let defaults = try makeDefaults(named: "invalidAllowlistedValue")
    let beforeDefaults = defaults.dictionaryRepresentation()
    let store = InMemoryRightClickStore(config: .default)
    var invalid = AppBackupDocument.current(
        settings: .serviceFixture,
        rightClick: .default,
        appVersion: "1.0.1",
        createdAt: Date()
    )
    invalid.settings.preferredTerminal = "unknown.terminal"

    #expect(throws: AppBackupValidationError.invalidPreferredTerminal("unknown.terminal")) {
        try AppBackupService.restore(invalid, userDefaults: defaults, rightClickStore: store)
    }
    #expect((defaults.dictionaryRepresentation() as NSDictionary).isEqual(to: beforeDefaults))
    #expect(store.replaceCallCount == 0)
}

@Test("未知右键配置项不会被恢复")
func invalidRightClickKeyDoesNotRestoreConfiguration() throws {
    let defaults = try makeDefaults(named: "invalidRightClickKey")
    let beforeDefaults = defaults.dictionaryRepresentation()
    let store = InMemoryRightClickStore(config: .default)
    let invalid = AppBackupDocument.current(
        settings: .serviceFixture,
        rightClick: RightClickConfig(enabled: ["unknownAction": false]),
        appVersion: "1.0.1",
        createdAt: Date()
    )

    #expect(throws: AppBackupValidationError.invalidRightClickKey("unknownAction")) {
        try AppBackupService.restore(invalid, userDefaults: defaults, rightClickStore: store)
    }
    #expect((defaults.dictionaryRepresentation() as NSDictionary).isEqual(to: beforeDefaults))
    #expect(store.config == .default)
    #expect(store.replaceCallCount == 0)
}

@Test("右键配置写入失败时回滚 UserDefaults 和右键配置")
func rightClickWriteFailureRollsBackEverything() throws {
    let defaults = try makeDefaults(named: "rollback")
    let beforeDefaults = defaults.dictionaryRepresentation()
    let oldRightClick = RightClickConfig(enabled: [RightClickItem.newFile.rawValue: true])
    let store = InMemoryRightClickStore(config: oldRightClick)
    store.failures = [.writeFailed]
    let document = AppBackupDocument.current(
        settings: .serviceFixture,
        rightClick: RightClickConfig(enabled: [RightClickItem.newFile.rawValue: false]),
        appVersion: "1.0.1",
        createdAt: Date()
    )

    #expect(throws: InMemoryRightClickStore.Error.writeFailed) {
        try AppBackupService.restore(document, userDefaults: defaults, rightClickStore: store)
    }
    #expect((defaults.dictionaryRepresentation() as NSDictionary).isEqual(to: beforeDefaults))
    #expect(store.config == oldRightClick)
    #expect(store.replaceCallCount == 2)
}

@Test("右键写入和回滚都失败时保留两个错误")
func rightClickRollbackFailureIsReported() throws {
    let defaults = try makeDefaults(named: "rollbackFailure")
    let oldRightClick = RightClickConfig(enabled: [RightClickItem.newFile.rawValue: true])
    let store = InMemoryRightClickStore(config: oldRightClick)
    store.failures = [.writeFailed, .rollbackFailed]
    let document = AppBackupDocument.current(
        settings: .serviceFixture,
        rightClick: RightClickConfig(enabled: [RightClickItem.newFile.rawValue: false]),
        appVersion: "1.0.1",
        createdAt: Date()
    )

    do {
        try AppBackupService.restore(document, userDefaults: defaults, rightClickStore: store)
        Issue.record("预期恢复失败")
    } catch let error as AppBackupRestoreError {
        guard case let .rollbackFailed(original, rollback) = error else {
            Issue.record("预期得到回滚失败错误，实际为 \(error)")
            return
        }
        #expect((original as? InMemoryRightClickStore.Error) == .writeFailed)
        #expect((rollback as? InMemoryRightClickStore.Error) == .rollbackFailed)
    }
    #expect(store.replaceCallCount == 2)
}

@Test("损坏 JSON 只被解码拒绝，不会触发配置写入")
func malformedDataIsRejectedBeforeRestore() throws {
    let defaults = try makeDefaults(named: "malformed")
    let beforeDefaults = defaults.dictionaryRepresentation()
    let store = InMemoryRightClickStore(config: .default)

    #expect(throws: DecodingError.self) {
        _ = try AppBackupService.decode(Data("not-json".utf8))
    }
    #expect((defaults.dictionaryRepresentation() as NSDictionary).isEqual(to: beforeDefaults))
    #expect(store.replaceCallCount == 0)
}

@Test("导出和导入通过文件访问边界处理成功")
func exportAndImportUseFileAccessBoundary() throws {
    let defaults = try makeDefaults(named: "fileAccessSuccess")
    let access = InMemoryBackupFileAccess()
    let url = URL(fileURLWithPath: "/tmp/MenuTools-test.menutoolsbackup")
    let rightClick = RightClickConfig(enabled: [RightClickItem.copyFileURL.rawValue: false])

    try AppBackupService.export(
        to: url,
        userDefaults: defaults,
        rightClick: rightClick,
        appVersion: "1.0.1",
        createdAt: Date(timeIntervalSince1970: 400),
        fileAccess: access
    )
    let imported = try AppBackupService.importDocument(from: url, fileAccess: access)

    #expect(imported.settings.menuBarIcon == "wrench.and.screwdriver.fill")
    #expect(imported.rightClick == rightClick)
    #expect(access.files[url] != nil)
}

@Test("导入文件读取失败会向调用方抛出原始错误")
func importReadFailureIsReported() {
    let access = InMemoryBackupFileAccess()
    access.readError = .readFailed

    #expect(throws: InMemoryBackupFileAccess.Error.readFailed) {
        _ = try AppBackupService.importDocument(
            from: URL(fileURLWithPath: "/tmp/missing.menutoolsbackup"),
            fileAccess: access
        )
    }
}

@Test("导出文件写入失败会向调用方抛出原始错误")
func exportWriteFailureIsReported() throws {
    let access = InMemoryBackupFileAccess()
    access.writeError = .writeFailed

    #expect(throws: InMemoryBackupFileAccess.Error.writeFailed) {
        try AppBackupService.export(
            to: URL(fileURLWithPath: "/tmp/write-failure.menutoolsbackup"),
            userDefaults: try makeDefaults(named: "fileAccessWriteFailure"),
            rightClick: .default,
            appVersion: "1.0.1",
            createdAt: Date(),
            fileAccess: access
        )
    }
}

private func makeDefaults(named name: String) throws -> UserDefaults {
    let suiteName = "AppBackupServiceTests.\(name)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set("wrench.and.screwdriver.fill", forKey: SettingsKey.menuBarIcon)
    defaults.set(false, forKey: SettingsKey.menuBarShowTitle)
    defaults.set(false, forKey: SettingsKey.togglesShowTitle)
    defaults.set("com.apple.Terminal", forKey: SettingsKey.preferredTerminal)
    defaults.set(true, forKey: SettingsKey.autoCheckUpdate)
    defaults.set("system", forKey: SettingsKey.appLanguage)
    defaults.set(false, forKey: SettingsKey.scrollEnabled)
    defaults.set(true, forKey: SettingsKey.scrollSmoothV)
    defaults.set(true, forKey: SettingsKey.scrollSmoothH)
    defaults.set(false, forKey: SettingsKey.scrollInvertV)
    defaults.set(false, forKey: SettingsKey.scrollInvertH)
    defaults.set(1.0, forKey: SettingsKey.scrollGain)
    defaults.set(0.35, forKey: SettingsKey.scrollDuration)
    defaults.set(8.0, forKey: SettingsKey.scrollMinStep)
    defaults.set(true, forKey: SettingsKey.scrollTouchpad)
    defaults.set(0, forKey: SettingsKey.scrollAccelKey)
    defaults.set(0, forKey: SettingsKey.scrollShiftKey)
    defaults.set(0, forKey: SettingsKey.scrollDisableKey)
    return defaults
}

private final class InMemoryRightClickStore: RightClickConfigPersisting, @unchecked Sendable {
    enum Error: Swift.Error, Equatable {
        case writeFailed
        case rollbackFailed
    }

    private(set) var config: RightClickConfig
    var failures: [Error] = []
    private(set) var replaceCallCount = 0

    init(config: RightClickConfig) {
        self.config = config
    }

    func load() -> RightClickConfig {
        config
    }

    func replace(_ config: RightClickConfig) throws {
        replaceCallCount += 1
        self.config = config
        if !failures.isEmpty {
            throw failures.removeFirst()
        }
    }
}

private final class InMemoryBackupFileAccess: AppBackupFileAccessing, @unchecked Sendable {
    enum Error: Swift.Error, Equatable {
        case readFailed
        case writeFailed
    }

    var files: [URL: Data] = [:]
    var readError: Error?
    var writeError: Error?

    func read(from url: URL) throws -> Data {
        if let readError { throw readError }
        return try #require(files[url])
    }

    func write(_ data: Data, to url: URL) throws {
        if let writeError { throw writeError }
        files[url] = data
    }
}

private extension AppBackupSettings {
    static let serviceFixture = AppBackupSettings(
        menuBarIcon: "terminal.fill",
        menuBarShowTitle: true,
        togglesShowTitle: true,
        preferredTerminal: "com.googlecode.iterm2",
        autoCheckUpdate: false,
        appLanguage: "zh-Hans",
        scrollEnabled: true,
        scrollSmoothVertical: false,
        scrollSmoothHorizontal: true,
        scrollInvertVertical: true,
        scrollInvertHorizontal: false,
        scrollGain: 1.5,
        scrollDuration: 0.5,
        scrollMinStep: 16,
        scrollTouchpadEmulation: false,
        scrollAccelModifier: 1 << 20,
        scrollShiftModifier: 1 << 17,
        scrollDisableModifier: 0
    )
}
