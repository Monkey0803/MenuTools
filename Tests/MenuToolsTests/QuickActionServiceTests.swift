import Foundation
import Testing
@testable import MenuTools

@MainActor
private final class RecordingQuickActionProcessRunner: QuickActionProcessRunning {
    private(set) var calls: [(String, [String])] = []
    var error: Error?

    func run(executable: String, arguments: [String]) throws {
        calls.append((executable, arguments))
        if let error { throw error }
    }
}

@MainActor
private final class RecordingQuickActionScriptRunner: QuickActionScriptRunning {
    private(set) var sources: [String] = []
    var error: Error?

    func run(source: String) throws {
        sources.append(source)
        if let error { throw error }
    }
}

@MainActor
private final class RecordingQuickActionWorkspace: QuickActionWorkspaceOpening {
    private(set) var openedURLs: [URL] = []
    var result = true

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return result
    }
}

@MainActor
@Test("快捷操作中心包含六个系统动作")
func quickActionsContainExpectedActions() {
    #expect(QuickAction.allCases == [
        .lockScreen,
        .emptyTrash,
        .restartFinder,
        .flushDNS,
        .openSystemSettings,
        .screenshot
    ])
}

@MainActor
private final class RecordingScreenLocker: ScreenLockRunning {
    var channel: ScreenLockChannel?
    private(set) var lockedChannels: [ScreenLockChannel] = []
    var error: Error?

    func availableChannel() -> ScreenLockChannel? { channel }

    func lock(using channel: ScreenLockChannel) throws {
        lockedChannels.append(channel)
        if let error { throw error }
    }
}

@MainActor
@Test("锁屏优先走无需授权的私有通道，不再依赖已被移除的 CGSession 路径")
func lockScreenPrefersPrivateChannel() throws {
    let processes = RecordingQuickActionProcessRunner()
    let locker = RecordingScreenLocker()
    locker.channel = .loginFramework
    let service = QuickActionService(processRunner: processes, screenLocker: locker)

    try service.perform(.lockScreen)

    #expect(locker.lockedChannels == [.loginFramework])
    // 私有通道不需要子进程，也不该退回旧路径。
    #expect(processes.calls.isEmpty)
}

@MainActor
@Test("私有通道不可用时锁屏回退到旧版 CGSession")
func lockScreenFallsBackToLegacyChannel() throws {
    let locker = RecordingScreenLocker()
    locker.channel = .legacyCGSession
    let service = QuickActionService(screenLocker: locker)

    try service.perform(.lockScreen)

    #expect(locker.lockedChannels == [.legacyCGSession])
}

@MainActor
@Test("没有可用锁屏通道时给出可读原因且不执行任何通道")
func lockScreenWithoutChannelReportsReadableReason() throws {
    let processes = RecordingQuickActionProcessRunner()
    let locker = RecordingScreenLocker()
    locker.channel = nil
    let service = QuickActionService(processRunner: processes, screenLocker: locker)

    #expect(throws: QuickActionError.lockUnsupported) {
        try service.perform(.lockScreen)
    }
    #expect(locker.lockedChannels.isEmpty)
    #expect(processes.calls.isEmpty)
    #expect(QuickActionError.lockUnsupported.errorDescription?.isEmpty == false)
}

@MainActor
@Test("锁屏通道执行失败会带上动作与原因")
func lockScreenFailureCarriesActionAndReason() throws {
    let locker = RecordingScreenLocker()
    locker.channel = .loginFramework
    locker.error = ScreenLockError.lockFailed(1)
    let service = QuickActionService(screenLocker: locker)

    #expect(throws: QuickActionError.self) {
        try service.perform(.lockScreen)
    }
}

@MainActor
@Test("默认锁屏通道在本机可用（macOS 26 起 CGSession 已移除，靠 login.framework 私有符号）")
func defaultScreenLockerFindsChannelOnThisSystem() {
    #expect(DefaultScreenLockRunner().availableChannel() == .loginFramework)
}

@MainActor
@Test("旧版 CGSession 通道按可执行文件存在性判定，并沿用 -suspend 参数")
func legacyScreenLockChannelUsesSuspendArgument() throws {
    let processes = RecordingQuickActionProcessRunner()
    let locker = DefaultScreenLockRunner(
        legacyCGSessionPath: "/tmp/CGSession",
        processRunner: processes,
        isExecutableFile: { $0 == "/tmp/CGSession" },
        isLoginFrameworkAvailable: { false }
    )

    #expect(locker.availableChannel() == .legacyCGSession)
    try locker.lock(using: .legacyCGSession)

    #expect(processes.calls.map(\.0) == ["/tmp/CGSession"])
    #expect(processes.calls.map(\.1) == [["-suspend"]])
}

@MainActor
@Test("两个通道都不可用时默认实现返回 nil，而不是退回死路径")
func defaultScreenLockerWithoutChannelsReturnsNil() {
    let locker = DefaultScreenLockRunner(
        legacyCGSessionPath: "/tmp/absent",
        processRunner: RecordingQuickActionProcessRunner(),
        isExecutableFile: { _ in false },
        isLoginFrameworkAvailable: { false }
    )

    #expect(locker.availableChannel() == nil)
}

@MainActor
@Test("清空废纸篓跳过空状态并在 Finder 报错后复核结果")
func emptyTrashVerifiesFinderResult() throws {
    let scripts = RecordingQuickActionScriptRunner()
    let service = QuickActionService(scriptRunner: scripts)

    try service.perform(.emptyTrash)

    let source = try #require(scripts.sources.first)
    #expect(source.contains("if (count of items of trash) is 0 then return"))
    #expect(source.contains("if (count of items of trash) is not 0 then error originalMessage number originalNumber"))
}

@MainActor
@Test("刷新 DNS 依次刷新缓存并重启 mDNSResponder")
func flushDNSUsesExpectedCommands() throws {
    let runner = RecordingQuickActionProcessRunner()
    let service = QuickActionService(processRunner: runner)

    try service.perform(.flushDNS)

    #expect(runner.calls.map(\.0) == ["/usr/bin/dscacheutil", "/usr/bin/killall"])
    #expect(runner.calls.map(\.1) == [["-flushcache"], ["-HUP", "mDNSResponder"]])
}

@MainActor
@Test("打开系统设置使用系统设置 URL")
func openSystemSettingsUsesSystemURL() throws {
    let workspace = RecordingQuickActionWorkspace()
    let service = QuickActionService(workspace: workspace)

    try service.perform(.openSystemSettings)

    #expect(workspace.openedURLs == [URL(string: "x-apple.systempreferences:")!])
}

@MainActor
@Test("截图使用 screencapture 写入剪贴板")
func screenshotUsesClipboardCapture() throws {
    let runner = RecordingQuickActionProcessRunner()
    let service = QuickActionService(processRunner: runner)

    try service.perform(.screenshot)

    #expect(runner.calls.count == 1)
    #expect(runner.calls.first?.0 == "/usr/sbin/screencapture")
    #expect(runner.calls.first?.1 == ["-x", "-c"])
}
