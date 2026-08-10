import Testing
@testable import MenuTools

@Test("专注模式状态解析支持常见输出")
func focusModeParserParsesState() {
    #expect(FocusModeParser.state(from: "enabled") == true)
    #expect(FocusModeParser.state(from: "disabled") == false)
    #expect(FocusModeParser.state(from: "unknown") == nil)
}

@Test("专注模式脚本包含 Control Center 和 Focus 控件")
func focusModeScriptTargetsControlCenter() {
    let script = FocusModeScript.toggle

    #expect(script.contains("ControlCenter"))
    #expect(script.contains("Focus"))
}
