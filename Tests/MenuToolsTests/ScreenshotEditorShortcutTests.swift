import SwiftUI
import Testing
@testable import MenuTools

@Test("标注器快捷键互不冲突，且不抢文本输入")
func screenshotEditorShortcutsDoNotClash() {
    let actions = ScreenshotEditorShortcutAction.allCases
    #expect(!actions.isEmpty)

    let combos = actions.map { "\($0.modifiers.rawValue)-\($0.key.character)" }
    #expect(Set(combos).count == actions.count)

    // 除 Esc 取消外都必须带修饰键：标注器有文本工具，无修饰键会抢走输入
    for action in actions where action != .cancel {
        #expect(action.modifiers != [], "\(action.rawValue) 必须带修饰键")
    }
    #expect(ScreenshotEditorShortcutAction.cancel.modifiers.isEmpty)
    #expect(ScreenshotEditorShortcutAction.cancel.key == .escape)

    // 每个动作都要有文案键，且各不相同（界面提示与无障碍标签共用它）
    let keys = actions.map(\.titleKey)
    #expect(keys.allSatisfy { !$0.isEmpty })
    #expect(Set(keys).count == actions.count)
}
