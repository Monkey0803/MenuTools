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
@Test("锁定屏幕使用 CGSession 安全参数")
func lockScreenUsesCGSession() throws {
    let runner = RecordingQuickActionProcessRunner()
    let service = QuickActionService(processRunner: runner)

    try service.perform(.lockScreen)

    #expect(runner.calls.map(\.0) == ["/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"])
    #expect(runner.calls.map(\.1) == [["-suspend"]])
}

@MainActor
@Test("清空废纸篓通过 Finder AppleScript 执行")
func emptyTrashUsesFinderScript() throws {
    let scripts = RecordingQuickActionScriptRunner()
    let service = QuickActionService(scriptRunner: scripts)

    try service.perform(.emptyTrash)

    #expect(scripts.sources == ["tell application \"Finder\" to empty trash"])
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
