import Foundation
import Testing
@testable import MenuTools

@Test("设置页状态提示：三档语义的符号与「是否错误」自洽")
func settingsStatusMessageKinds() {
    #expect(SettingsStatusMessage(success: "已清理").isError == false)
    #expect(SettingsStatusMessage(info: "共 3 项").isError == false)
    #expect(SettingsStatusMessage(kind: .failure, text: "失败").isError)

    #expect(SettingsStatusMessage(success: "x").symbolName == "checkmark.circle.fill")
    #expect(SettingsStatusMessage(kind: .failure, text: "x").symbolName == "exclamationmark.triangle.fill")
    #expect(SettingsStatusMessage(info: "x").symbolName == "info.circle")

    // 三档符号互不相同，界面上才能一眼区分
    let symbols = SettingsStatusMessage.Kind.allCases.map { SettingsStatusMessage(kind: $0, text: "x").symbolName }
    #expect(Set(symbols).count == SettingsStatusMessage.Kind.allCases.count)
}

@Test("失败提示沿用错误自身的本地化文案")
func settingsStatusMessageWrapsAnyError() {
    let message = SettingsStatusMessage(failure: QuickActionError.lockUnsupported)
    #expect(message.text == QuickActionError.lockUnsupported.errorDescription)
    #expect(message.isError)
    #expect(!message.text.isEmpty)
}
