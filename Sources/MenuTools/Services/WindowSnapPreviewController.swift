import AppKit

/// 拖拽吸附时显示目标落点的半透明预览窗口。
///
/// 只负责渲染：落点由 `WindowSnapPreviewPlanner` 计算，方便单独测试。
@MainActor
final class WindowSnapPreviewController {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ plan: WindowSnapPreviewPlan) {
        let panel = panel ?? makePanel()
        self.panel = panel
        if panel.frame != plan.frame {
            panel.setFrame(plan.frame, display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = WindowSnapPreviewPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = WindowSnapPreviewView()
        return panel
    }
}

/// 预览面板不能抢焦点，否则拖动过程中会把前台应用切走。
private final class WindowSnapPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WindowSnapPreviewView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 2),
            xRadius: 10,
            yRadius: 10
        )
        accent.withAlphaComponent(0.16).setFill()
        path.fill()
        accent.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 3
        path.stroke()
    }
}
