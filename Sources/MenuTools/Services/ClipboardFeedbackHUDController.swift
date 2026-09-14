import AppKit
import SwiftUI

/// Popover 关闭后仍可见的剪贴板操作反馈，不抢占当前 App 的键盘焦点。
@MainActor
final class ClipboardFeedbackHUDController {
    static let shared = ClipboardFeedbackHUDController()

    /// 展示时长：默认 1.8 秒，测试可注入更短的值。
    static let defaultDismissInterval: TimeInterval = 1.8

    private let dismissInterval: TimeInterval
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// 当前展示的反馈；nil 表示已隐藏。界面与测试都以它为准。
    private(set) var presentedFeedback: ClipboardCopyFeedback?
    var isPresenting: Bool { presentedFeedback != nil }

    init(dismissInterval: TimeInterval = ClipboardFeedbackHUDController.defaultDismissInterval) {
        self.dismissInterval = dismissInterval
    }

    func show(_ feedback: ClipboardCopyFeedback) {
        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: ClipboardFeedbackHUDView(feedback: feedback))
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 150, y: frame.minY + 96))
        }
        panel.orderFrontRegardless()
        presentedFeedback = feedback

        // 用 Task 而不是 Timer：不依赖 run loop，连续展示时重新计时也更直观。
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(dismissInterval))
            guard !Task.isCancelled else { return }
            self.panel?.orderOut(nil)
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

private struct ClipboardFeedbackHUDView: View {
    let feedback: ClipboardCopyFeedback

    var body: some View {
        Label(
            L(feedback.localizationKey),
            systemImage: feedback.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.callout.weight(.medium))
        .foregroundStyle(feedback.isSuccess ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
