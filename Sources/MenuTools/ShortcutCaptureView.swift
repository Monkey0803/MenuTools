import AppKit
import SwiftUI

/// 通用全局快捷键录入控件。
struct GlobalShortcutCaptureView: NSViewRepresentable {
    let isRecording: Bool
    let onCapture: (GlobalShortcut?) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onCapture = onCapture
        nsView.isRecording = isRecording
        if isRecording {
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView, nsView.isRecording else { return }
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    final class RecorderView: NSView {
        var onCapture: ((GlobalShortcut?) -> Void)?
        var isRecording = false {
            didSet { updateLocalMonitor() }
        }
        private var localMonitor: Any?

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            capture(event)
        }

        private func capture(_ event: NSEvent) {
            if event.keyCode == 53 {
                onCapture?(nil)
                return
            }
            onCapture?(GlobalShortcut(
                keyCode: event.keyCode,
                modifiers: GlobalShortcutCatalog.normalizedModifiers(event.modifierFlags)
            ))
        }

        private func updateLocalMonitor() {
            if isRecording, localMonitor == nil {
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, self.isRecording else { return event }
                    self.capture(event)
                    return nil
                }
            } else if !isRecording, let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
