import AppKit
import SwiftUI

/// 辅助功能权限提示：统一各设置页的「未授权」呈现与一键跳转。
///
/// 权限是窗口管理、应用启动器、翻译与场景快捷键最高频的失败原因。此前各页各写一行静态橙色
/// 文字（翻译页甚至没有任何提示），用户既不知道去哪授权，也不理解功能为何没反应。
///
/// 用法：`AccessibilityPermissionNotice(isTrusted: service.isAccessibilityTrusted)`，
/// 并传入服务的重新读取方法；`refresh` 会在页面出现以及从系统设置切回本应用时执行，
/// 这样用户授权后回到应用，提示会自动消失。
struct AccessibilityPermissionNotice: View {
    let isTrusted: Bool
    var refresh: () -> Void = {}

    var body: some View {
        Group {
            if !isTrusted {
                HStack(spacing: 8) {
                    Label(L("shortcut.permission"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(L("shortcut.openPermission"), action: openSettings)
                        .controlSize(.small)
                }
            }
        }
        .onAppear(perform: refresh)
        // 去系统设置授权后切回来要能立刻反映：此前权限只在 start/stop 时读取。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func openSettings() {
        guard let url = RuntimePermissionSettingsLink.url(for: .accessibility) else { return }
        NSWorkspace.shared.open(url)
    }
}
