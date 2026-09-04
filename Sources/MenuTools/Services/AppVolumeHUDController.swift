import AppKit
import SwiftUI

@MainActor
final class AppVolumeHUDController {
    static let shared = AppVolumeHUDController()

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    func show(volume: Double, isMuted: Bool) {
        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: AppVolumeHUDView(volume: volume, isMuted: isMuted))
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 110, y: frame.midY - 58))
        }
        panel.orderFrontRegardless()
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 116),
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

private struct AppVolumeHUDView: View {
    let volume: Double
    let isMuted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: AppVolumeIconPolicy.symbolName(volume: volume, isMuted: isMuted))
                .font(.system(size: 29, weight: .medium))
            ProgressView(value: isMuted ? 0 : volume)
                .progressViewStyle(.linear)
            Text(isMuted ? L("volume.hud.muted") : "\(Int((volume * 100).rounded()))%")
                .font(.headline.monospacedDigit())
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
