import Foundation
import Testing

/// 辅助功能权限是窗口管理、应用启动器、翻译与场景快捷键最高频的失败原因。
/// 这里守住「统一提示」这一不变量：此前窗口管理与启动器各写一行静态橙色文字、翻译页完全没有提示，
/// 用户既不知道去哪授权，也不理解功能为何没反应。
@Test("依赖辅助功能权限的设置页都使用统一的权限提示组件")
func accessibilityDependentSettingsPagesUseSharedNotice() throws {
    // #filePath → Tests/MenuToolsTests/xxx.swift，向上三级到仓库根。
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let pages = [
        "WindowManagementSettingsView",
        "AppLaunchSettingsView",
        "TranslationSettingsView"
    ]
    for page in pages {
        let url = repositoryRoot.appendingPathComponent("Sources/MenuTools/\(page).swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("AccessibilityPermissionNotice("),
            "\(page) 未使用统一的辅助功能权限提示组件"
        )
        #expect(
            !source.contains("Label(L(\"shortcut.permission\"), systemImage: \"exclamationmark.triangle.fill\")"),
            "\(page) 仍在用不带跳转入口的静态权限文字"
        )
    }
}
