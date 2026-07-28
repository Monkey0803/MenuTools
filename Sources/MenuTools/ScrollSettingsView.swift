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
                axisSection
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
                sliderRow(title: L("scroll.gain"), value: $gain, range: 0.5...3.0, unit: "×")
                Divider()
                sliderRow(title: L("scroll.duration"), value: $duration, range: 0.1...0.8, unit: "s")
                Divider()
                sliderRow(title: L("scroll.minStep"), value: $minStep, range: 1...30, unit: "px")
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
            Text(String(format: unit == "×" || unit == "s" ? "%.2f%@" : "%.0f%@", value.wrappedValue, unit))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
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
