import AppKit
import SwiftUI

/// 窗口布局与快捷键设置。
struct WindowManagementSettingsView: View {
    @Bindable private var shortcutService: WindowShortcutService
    @State private var recordingLayout: WindowLayout?
    @State private var errorMessage: String?

    init(shortcutService: WindowShortcutService = .shared) {
        self.shortcutService = shortcutService
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("window.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !shortcutService.isAccessibilityTrusted {
                    Label(L("shortcut.permission"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // 必须放在滚动内容顶部，确保窗口打开时就已创建并可成为第一响应者。
                WindowShortcutCaptureView(isRecording: recordingLayout != nil) { shortcut in
                    guard let layout = recordingLayout else { return }
                    recordingLayout = nil
                    guard let shortcut else { return }
                    do {
                        try shortcutService.setBinding(shortcut, for: layout)
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .frame(width: 1, height: 1)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    ForEach(WindowLayout.allCases) { layout in
                        layoutRow(layout)
                    }
                }

                HStack(spacing: 10) {
                    Button(L("window.save")) {
                        do {
                            try WindowManagementService.shared.saveFocusedWindowFrame()
                            errorMessage = nil
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    Button(L("window.restore")) {
                        do {
                            try WindowManagementService.shared.restoreFocusedWindowFrame()
                            errorMessage = nil
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.bordered)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let lastError = shortcutService.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

            }
            .padding(16)
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .navigationTitle(L("settings.title"))
        .task { shortcutService.start() }
    }

    private func layoutRow(_ layout: WindowLayout) -> some View {
        HStack(spacing: 8) {
            Button {
                apply(layout)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: layout.symbol)
                        .frame(width: 18)
                    Text(L(layout.titleKey))
                        .font(.callout)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Spacer(minLength: 2)
                    Text(recordingLayout == layout ? L("shortcut.recording") : (shortcutService.binding(for: layout)?.displayName ?? L("settings.unset")))
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .foregroundStyle(recordingLayout == layout ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .contentShape(.rect(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .help(L("window.applied", L(layout.titleKey)))

            Button {
                recordingLayout = recordingLayout == layout ? nil : layout
            } label: {
                Image(systemName: recordingLayout == layout ? "xmark" : "record.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .help(L("shortcut.record"))

            if shortcutService.binding(for: layout) != nil {
                Button {
                    shortcutService.clearBinding(for: layout)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("shortcut.clear"))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 9))
    }

    private func apply(_ layout: WindowLayout) {
        do {
            try WindowManagementService.shared.apply(layout)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct WindowShortcutCaptureView: NSViewRepresentable {
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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard isRecording else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRecording else { return }
                self.window?.makeFirstResponder(self)
            }
        }

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
