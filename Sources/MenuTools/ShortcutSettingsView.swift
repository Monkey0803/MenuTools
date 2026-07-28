import SwiftUI
import Carbon.HIToolbox

/// 快捷键绑定设置页
struct ShortcutSettingsView: View {
    @ObservedObject private var manager = ShortcutManager.shared
    @State private var recording: ShortcutAction?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(spacing: 0) {
                    ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { Divider() }
                        row(action)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
            .padding(20)
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "command.square.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [.purple, .indigo],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(L("sc.title"))
                    .font(.title3.weight(.semibold))
                Text(L("sc.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        HStack(spacing: 12) {
            Image(systemName: action.symbol)
                .font(.body)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(L(action.titleKey))
                .font(.body)
            Spacer(minLength: 0)
            recorderButton(action)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func recorderButton(_ action: ShortcutAction) -> some View {
        let isRecording = recording == action
        let combo = manager.combo(for: action)
        return HStack(spacing: 6) {
            Button {
                if isRecording {
                    recording = nil
                } else {
                    recording = action
                }
            } label: {
                Text(isRecording ? L("sc.recording") : (combo?.display ?? L("sc.unset")))
                    .font(.callout.monospaced())
                    .frame(minWidth: 92)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .glassEffect(isRecording ? .regular.tint(.accentColor.opacity(0.3)) : .regular, in: .rect(cornerRadius: 8))
            .background(KeyRecorder(isRecording: isRecording) { combo in
                manager.setCombo(combo, for: action)
                recording = nil
            })

            if combo != nil && !isRecording {
                Button {
                    manager.setCombo(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L("sc.clear"))
            }
        }
    }
}

/// 用 NSView 承载本地按键监听：录制期间捕获下一个按键组合
private struct KeyRecorder: NSViewRepresentable {
    let isRecording: Bool
    let onCapture: (KeyCombo) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCapture = onCapture
        if isRecording {
            context.coordinator.startMonitoring()
        } else {
            context.coordinator.stopMonitoring()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onCapture: ((KeyCombo) -> Void)?
        private var monitor: Any?

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // 忽略纯修饰键
                let combo = KeyComboFactory.make(from: event)
                self.onCapture?(combo)
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { stopMonitoring() }
    }
}

/// 由 NSEvent 生成 KeyCombo（Cocoa 修饰符 → Carbon 修饰符 + 显示字符串）
enum KeyComboFactory {
    static func make(from event: NSEvent) -> KeyCombo {
        var carbon: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        var display = ""
        if flags.contains(.control) { display += "⌃" }
        if flags.contains(.option) { display += "⌥" }
        if flags.contains(.shift) { display += "⇧" }
        if flags.contains(.command) { display += "⌘" }
        display += keyName(for: event)

        return KeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbon, display: display)
    }

    private static func keyName(for event: NSEvent) -> String {
        let specials: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
            kVK_Delete: "⌫", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2",
            kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12"
        ]
        if let name = specials[Int(event.keyCode)] { return name }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
