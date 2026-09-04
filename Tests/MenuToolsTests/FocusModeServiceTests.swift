import Testing
@testable import MenuTools

@Test("专注模式状态解析支持常见输出")
func focusModeParserParsesState() {
    #expect(FocusModeParser.state(from: "enabled") == true)
    #expect(FocusModeParser.state(from: "disabled") == false)
    #expect(FocusModeParser.state(from: "unknown") == nil)
}

@Test("后台自动化不允许通过控制中心读取专注模式")
@MainActor
func automationFocusRefreshDoesNotPresentControlCenter() {
    #expect(!FocusModeRefreshPolicy.permitsControlCenterPresentation(for: .automation))
    #expect(FocusModeRefreshPolicy.permitsControlCenterPresentation(for: .userInitiated))

    let executor = FocusModeScriptExecutorSpy(states: [true, false])
    let service = FocusModeService(scriptExecutor: executor)
    service.refresh(trigger: .automation)

    #expect(executor.stateSources.isEmpty)
    #expect(executor.executedSources.isEmpty)
    #expect(service.isEnabled == nil)
    #expect(service.isDoNotDisturbEnabled == nil)

    service.refresh()
    #expect(executor.stateSources == [FocusModeScript.readState, FocusModeScript.readDoNotDisturb])
    #expect(service.isEnabled == true)
    #expect(service.isDoNotDisturbEnabled == false)
}

@Test("用户主动切换专注模式后仍会刷新状态")
@MainActor
func userInitiatedFocusToggleExecutesAndRefreshes() throws {
    let executor = FocusModeScriptExecutorSpy(states: [true, false])
    let service = FocusModeService(scriptExecutor: executor)

    try service.toggle()

    #expect(executor.executedSources == [FocusModeScript.toggle])
    #expect(executor.stateSources == [FocusModeScript.readState, FocusModeScript.readDoNotDisturb])
    #expect(service.isEnabled == true)
    #expect(service.isDoNotDisturbEnabled == false)
}

@Test("专注模式脚本包含 Control Center 和 Focus 控件")
func focusModeScriptTargetsControlCenter() {
    let script = FocusModeScript.toggle

    #expect(script.contains("ControlCenter"))
    #expect(script.contains("whose description contains"))
    #expect(!script.contains("click menu bar item \"Control Center\""))
    #expect(script.contains("Focus"))
}

@Test("独立勿扰模式脚本包含勿扰目标")
func doNotDisturbScriptTargetsDedicatedMode() {
    let script = FocusModeScript.toggleDoNotDisturb

    #expect(script.contains("Do Not Disturb"))
    #expect(script.contains("ControlCenter"))
}

@MainActor
private final class FocusModeScriptExecutorSpy: FocusModeScriptExecuting {
    private var states: [Bool?]
    private(set) var stateSources: [String] = []
    private(set) var executedSources: [String] = []

    init(states: [Bool?]) {
        self.states = states
    }

    func state(using source: String) -> Bool? {
        stateSources.append(source)
        return states.isEmpty ? nil : states.removeFirst()
    }

    func execute(_ source: String) throws {
        executedSources.append(source)
    }
}
