import Carbon.HIToolbox
import Testing
@testable import MenuTools

@Test("空间切换脚本使用左方向键和 Control 修饰键")
func leftSpaceCommandUsesControlLeft() {
    let script = SpaceShortcutScript.source(keyCode: kVK_LeftArrow)

    #expect(script.contains("key code 123 using control down"))
}

@Test("空间切换脚本使用右方向键和 Control 修饰键")
func rightSpaceCommandUsesControlRight() {
    let script = SpaceShortcutScript.source(keyCode: kVK_RightArrow)

    #expect(script.contains("key code 124 using control down"))
}

@Test("Automation AppleScript 错误映射为 Automation 权限结果")
func automationScriptErrorMapsToAutomationRequired() {
    let error: NSDictionary = [
        "NSAppleScriptErrorNumber": -1743,
        "NSAppleScriptErrorMessage": "Not authorized to send Apple events"
    ]

    #expect(SpaceService.result(for: error) == .automationRequired)
}

@Test("非权限 AppleScript 错误保留执行失败信息")
func scriptErrorMapsToExecutionFailed() {
    let error: NSDictionary = [
        "NSAppleScriptErrorNumber": -1708,
        "NSAppleScriptErrorMessage": "Event not handled"
    ]

    #expect(SpaceService.result(for: error) == .executionFailed(
        L("space.executionFailed", "Event not handled")
    ))
}
