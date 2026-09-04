import AppKit
import SwiftUI

/// Popover 关闭后仍可见的剪贴板操作反馈，不抢占当前 App 的键盘焦点。
@MainActor
final class ClipboardFeedbackHUDController {
    static let shared = ClipboardFeedbackHUDController()

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    func show(_ feedback: ClipboardCopyFeedback) {
        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: ClipboardFeedbackHUDView(feedback: feedback))
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 150, y: frame.minY + 96))
        }
        panel.orderFrontRegardless()

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.panel?.orderOut(nil)
            }
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

    private var isSuccess: Bool {
        feedback == .copied || feedback == .pasted
    }

    var body: some View {
        Label(
            L(feedback.localizationKey),
            systemImage: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.callout.weight(.medium))
        .foregroundStyle(isSuccess ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
