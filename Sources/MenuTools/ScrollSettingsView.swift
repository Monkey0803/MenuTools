import SwiftUI

/// 平滑滚动设置页
struct ScrollSettingsView: View {
    @ObservedObject private var engine = SmoothScrollEngine.shared

    @AppStorage(SettingsKey.scrollEnabled) private var enabled = false
    @AppStorage(SettingsKey.scrollSmoothV) private var smoothV = true
    @AppStorage(SettingsKey.scrollSmoothH) private var smoothH = true
    @AppStorage(SettingsKey.scrollInvertV) private var invertV = false
    @AppStorage(SettingsKey.scrollInvertH) private var invertH = false
    @AppStorage(SettingsKey.scrollGain) private var gain = 1.0
    @AppStorage(SettingsKey.scrollDuration) private var duration = 0.35
    @AppStorage(SettingsKey.scrollMinStep) private var minStep = 8.0
    @AppStorage(SettingsKey.scrollTouchpad) private var touchpad = true
    @AppStorage(SettingsKey.scrollAccelKey) private var accelKey = 0
    @AppStorage(SettingsKey.scrollShiftKey) private var shiftKey = 0
    @AppStorage(SettingsKey.scrollDisableKey) private var disableKey = 0

    @State private var accessibilityOK = SmoothScrollEngine.shared.accessibilityGranted
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                masterSwitch
                if enabled && !accessibilityOK {
                    permissionHint
                }
                smoothSection
                modifierSection
                axisSection
                resetButton
            }
            .padding(20)
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .onReceive(refreshTimer) { _ in
            accessibilityOK = engine.accessibilityGranted
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "computermouse.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [.green, .teal],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(L("scroll.title"))
                    .font(.title3.weight(.semibold))
                Text(L("scroll.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var masterSwitch: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("scroll.enable"))
                    .font(.body.weight(.medium))
                Text(L("scroll.enable.desc"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .onChange(of: enabled) { _, _ in engine.reload() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private var permissionHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(L("scroll.needAccessibility"))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L("scroll.openAccessibility")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.2)), in: .rect(cornerRadius: 12))
    }

    // MARK: - 平滑滚动参数

    private var smoothSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(icon: "slider.horizontal.3", title: L("scroll.section.smooth"))
            VStack(alignment: .leading, spacing: 14) {
                sliderRow(title: L("scroll.gain"), value: $gain, range: 0.1...10.0, unit: "×")
                Divider()
                sliderRow(title: L("scroll.duration"), value: $duration, range: 0.05...2.0, unit: "s")
                Divider()
                sliderRow(title: L("scroll.minStep"), value: $minStep, range: 1...100, unit: "px")
                Divider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("scroll.touchpad"))
                            .font(.body)
                        Text(L("scroll.touchpad.desc"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $touchpad)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: touchpad) { _, _ in engine.reload() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .frame(width: 88, alignment: .leading)
            Slider(value: value, in: range)
                .onChange(of: value.wrappedValue) { _, _ in engine.reload() }
            // 数值步进框（可直接微调）
            TextField("", value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .onChange(of: value.wrappedValue) { _, _ in engine.reload() }
            Stepper("", value: value, in: range, step: range.upperBound > 10 ? 1 : 0.05)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in engine.reload() }
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
        }
    }

    // MARK: - 修饰键（加速/转换/禁用）

    private var modifierSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(icon: "keyboard", title: L("scroll.section.modifier"))
            VStack(spacing: 0) {
                modifierRow(title: L("scroll.accel"), desc: L("scroll.accel.desc"), value: $accelKey)
                Divider()
                modifierRow(title: L("scroll.shiftAxis"), desc: L("scroll.shiftAxis.desc"), value: $shiftKey)
                Divider()
                modifierRow(title: L("scroll.disableKey"), desc: L("scroll.disableKey.desc"), value: $disableKey)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func modifierRow(title: String, desc: String, value: Binding<Int>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(desc).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            ModifierRecorder(rawValue: value) { engine.reload() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    // MARK: - 恢复预设

    private var resetButton: some View {
        Button(L("scroll.reset")) {
            gain = 1.0; duration = 0.35; minStep = 8
            touchpad = true; invertV = false; invertH = false
            smoothV = true; smoothH = true
            accelKey = 0; shiftKey = 0; disableKey = 0
            engine.reload()
        }
        .frame(maxWidth: .infinity)
        .disabled(!enabled)
    }

    // MARK: - 轴向独立

    private var axisSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(icon: "arrow.up.and.down.and.arrow.left.and.right", title: L("scroll.section.axis"))
            VStack(spacing: 0) {
                axisRow(title: L("scroll.axis.vertical"), smooth: $smoothV, invert: $invertV)
                Divider()
                axisRow(title: L("scroll.axis.horizontal"), smooth: $smoothH, invert: $invertH)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func axisRow(title: String, smooth: Binding<Bool>, invert: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .frame(width: 60, alignment: .leading)
            Spacer(minLength: 0)
            Toggle(L("scroll.smooth"), isOn: smooth)
                .toggleStyle(.checkbox)
                .onChange(of: smooth.wrappedValue) { _, _ in engine.reload() }
            Toggle(L("scroll.invert"), isOn: invert)
                .toggleStyle(.checkbox)
                .onChange(of: invert.wrappedValue) { _, _ in engine.reload() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    private func sectionLabel(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(title)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }
}

/// 修饰键录制器：点击后按住任意修饰键组合即记录（存 Cocoa ModifierFlags rawValue）
private struct ModifierRecorder: View {
    @Binding var rawValue: Int
    var onChange: () -> Void
    @State private var recording = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording.toggle()
            } label: {
                Text(recording ? L("sc.recording") : (display.isEmpty ? L("sc.unset") : display))
                    .font(.callout)
                    .frame(minWidth: 96)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(recording ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .glassEffect(recording ? .regular.tint(.accentColor.opacity(0.3)) : .regular, in: .rect(cornerRadius: 8))
            .background(ModifierMonitor(recording: recording) { flags in
                rawValue = Int(bitPattern: UInt(flags))
                recording = false
                onChange()
            })
            if rawValue != 0 && !recording {
                Button {
                    rawValue = 0
                    onChange()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(rawValue))
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }
}

/// 监听 flagsChanged 捕获修饰键
private struct ModifierMonitor: NSViewRepresentable {
    let recording: Bool
    let onCapture: (UInt) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCapture = onCapture
        recording ? context.coordinator.start() : context.coordinator.stop()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onCapture: ((UInt) -> Void)?
        private var monitor: Any?
        private let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                let masked = event.modifierFlags.intersection(self.relevant)
                if !masked.isEmpty {
                    self.onCapture?(masked.rawValue)
                }
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
        deinit { stop() }
    }
}
