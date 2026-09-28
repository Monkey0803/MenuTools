import AppKit
import SwiftUI

/// HUD 的统一展示内容：剪贴板反馈与「快捷键失败」等任意文案都收敛到这里。
struct TransientHUDMessage: Equatable {
    var text: String
    var isSuccess: Bool
    var systemImage: String
}

/// Popover 关闭后仍可见的瞬时反馈，不抢占当前 App 的键盘焦点。
///
/// 除剪贴板反馈外，它也是全局快捷键、自动应用规则这类「没有设置页在屏」路径的失败出口：
/// 那些路径只写状态字段，用户看不到任何东西，只会以为按键没生效。
@MainActor
final class ClipboardFeedbackHUDController {
    static let shared = ClipboardFeedbackHUDController()

    /// 展示时长：默认 1.8 秒，测试可注入更短的值。
    static let defaultDismissInterval: TimeInterval = 1.8

    private let dismissInterval: TimeInterval
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// 当前展示的内容；nil 表示已隐藏。界面与测试都以它为准。
    private(set) var presentedMessage: TransientHUDMessage?
    /// 剪贴板反馈路径下额外记录具体反馈，供既有调用方与测试判断语义。
    private(set) var presentedFeedback: ClipboardCopyFeedback?
    var isPresenting: Bool { presentedMessage != nil }

    init(dismissInterval: TimeInterval = ClipboardFeedbackHUDController.defaultDismissInterval) {
        self.dismissInterval = dismissInterval
    }

    func show(_ feedback: ClipboardCopyFeedback) {
        presentedFeedback = feedback
        present(TransientHUDMessage(
            text: L(feedback.localizationKey),
            isSuccess: feedback.isSuccess,
            systemImage: feedback.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        ))
    }

    /// 展示一条已经是最终文案的消息（例如快捷键触发失败的原因）。
    func show(message: String, isSuccess: Bool) {
        presentedFeedback = nil
        present(TransientHUDMessage(
            text: message,
            isSuccess: isSuccess,
            systemImage: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        ))
    }

    private func present(_ message: TransientHUDMessage) {
        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: ClipboardFeedbackHUDView(message: message))
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 150, y: frame.minY + 96))
        }
        panel.orderFrontRegardless()
        presentedMessage = message

        // 用 Task 而不是 Timer：不依赖 run loop，连续展示时重新计时也更直观。
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(dismissInterval))
            guard !Task.isCancelled else { return }
            self.panel?.orderOut(nil)
            self.presentedMessage = nil
            self.presentedFeedback = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }
}

/// 「没有设置页在屏」的路径（全局快捷键、自动应用规则）的失败提示出口。
@MainActor
protocol TransientMessagePresenting {
    func show(message: String, isSuccess: Bool)
}

/// 默认实现：复用上面那个不抢焦点的浮层。
@MainActor
struct ClipboardHUDMessagePresenter: TransientMessagePresenting {
    func show(message: String, isSuccess: Bool) {
        ClipboardFeedbackHUDController.shared.show(message: message, isSuccess: isSuccess)
    }
}

private struct ClipboardFeedbackHUDView: View {
    let message: TransientHUDMessage

    var body: some View {
        Label(message.text, systemImage: message.systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(message.isSuccess ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
