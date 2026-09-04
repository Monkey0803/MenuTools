import AppKit
import SwiftUI

/// 窗口布局与快捷键设置。
struct WindowManagementSettingsView: View {
    @Bindable private var shortcutService: WindowShortcutService
    @Bindable private var windowService: WindowManagementService
    @State private var recordingLayout: WindowLayout?
    @State private var isRecordingQuickAccessShortcut = false
    @State private var errorMessage: String?
    @State private var newPresetName = ""
    @State private var presetLayout: WindowLayout = .leftHalf
    @State private var ruleLayout: WindowLayout = .leftHalf

    init(
        shortcutService: WindowShortcutService = .shared,
        windowService: WindowManagementService = .shared
    ) {
        self.shortcutService = shortcutService
        self.windowService = windowService
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

                quickAccessShortcutSection

                managerOptionsSection
                presetSection
                applicationRulesSection
                exclusionSection

                // 必须放在滚动内容顶部，确保窗口打开时就已创建并可成为第一响应者。
                WindowShortcutCaptureView(isRecording: recordingLayout != nil || isRecordingQuickAccessShortcut) { shortcut in
                    if isRecordingQuickAccessShortcut {
                        isRecordingQuickAccessShortcut = false
                        guard let shortcut else { return }
                        do {
                            try shortcutService.setQuickAccessBinding(shortcut)
                            errorMessage = nil
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        return
                    }
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
                    Button {
                        arrangeWindows()
                    } label: {
                        Label(L("window.arrange"), systemImage: "square.grid.2x2")
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
    }

    private var quickAccessShortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("window.quickAccess.shortcut"))
                .font(.headline)
            Text(L("window.quickAccess.shortcutDescription"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(shortcutService.quickAccessBinding?.displayName ?? L("settings.unset"))
                    .font(.callout.monospaced())
                    .foregroundStyle(shortcutService.quickAccessBinding == nil ? .secondary : .primary)
                Spacer()
                Button {
                    recordingLayout = nil
                    errorMessage = nil
                    isRecordingQuickAccessShortcut.toggle()
                } label: {
                    Image(systemName: isRecordingQuickAccessShortcut ? "xmark" : "record.circle")
                }
                .help(L("shortcut.record"))
                if shortcutService.quickAccessBinding != nil {
                    Button {
                        shortcutService.clearQuickAccessBinding()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(L("shortcut.clear"))
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var managerOptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("window.manager.section"))
                .font(.headline)

            optionSlider(
                title: L("window.manager.padding"),
                value: optionBinding(\WindowManagerOptions.screenPadding),
                range: 0...40
            )
            optionSlider(
                title: L("window.manager.gap"),
                value: optionBinding(\WindowManagerOptions.windowGap),
                range: 0...40
            )
            optionSlider(
                title: L("window.manager.snapDistance"),
                value: optionBinding(\WindowManagerOptions.snapDistance),
                range: 8...80
            )

            Toggle(L("window.manager.edgeSnapping"), isOn: Binding(
                get: { windowService.configuration.edgeSnappingEnabled },
                set: { windowService.setEdgeSnappingEnabled($0) }
            ))
            Toggle(L("window.manager.autoRules"), isOn: Binding(
                get: { windowService.configuration.automaticApplicationRules },
                set: { windowService.setAutomaticApplicationRulesEnabled($0) }
            ))
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("window.manager.presets"))
                .font(.headline)
            HStack {
                TextField(L("window.manager.presetName"), text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $presetLayout) {
                    ForEach(WindowLayout.allCases) { layout in
                        Text(L(layout.titleKey)).tag(layout)
                    }
                }
                .labelsHidden()
                Button {
                    windowService.addPreset(name: newPresetName, layout: presetLayout)
                    newPresetName = ""
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(windowService.configuration.presets) { preset in
                HStack {
                    WindowLayoutIcon(layout: preset.layout)
                        .frame(width: 18, height: 14)
                    Text(preset.name)
                    Spacer()
                    Button(L("window.apply")) { apply(preset) }
                    Button { windowService.removePreset(preset) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var applicationRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("window.manager.applicationRules"))
                .font(.headline)
            if let application = windowService.focusedApplicationInfo() {
                HStack {
                    Text(L("window.manager.currentApp", application.name))
                        .lineLimit(1)
                    Picker("", selection: $ruleLayout) {
                        ForEach(WindowLayout.allCases) { layout in
                            Text(L(layout.titleKey)).tag(layout)
                        }
                    }
                    .labelsHidden()
                    Button(L("window.manager.bind")) {
                        windowService.addOrUpdateApplicationRule(for: application, layout: ruleLayout)
                    }
                }
            } else {
                Text(L("window.manager.noCurrentApp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(windowService.configuration.applicationRules) { rule in
                HStack {
                    Toggle(isOn: Binding(
                        get: { rule.isEnabled },
                        set: { windowService.setApplicationRuleEnabled($0, for: rule) }
                    )) {
                        Text(rule.applicationName)
                        Text(L(rule.layout.titleKey))
                    }
                    Button { windowService.removeApplicationRule(rule) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var exclusionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("window.manager.exclusions"))
                .font(.headline)
            if let application = windowService.focusedApplicationInfo(),
               !windowService.configuration.excludedBundleIdentifiers.contains(application.bundleIdentifier) {
                Button(L("window.manager.excludeCurrent", application.name)) {
                    windowService.addExcludedApplication(application)
                }
                .font(.caption)
            }
            ForEach(windowService.configuration.excludedBundleIdentifiers, id: \.self) { bundleIdentifier in
                HStack {
                    Text(bundleIdentifier)
                    Spacer()
                    Button { windowService.removeExcludedApplication(bundleIdentifier) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func optionSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))")
                .font(.caption.monospacedDigit())
                .frame(width: 28, alignment: .trailing)
        }
    }

    private func optionBinding(_ keyPath: WritableKeyPath<WindowManagerOptions, CGFloat>) -> Binding<Double> {
        Binding(
            get: { Double(windowService.configuration.options[keyPath: keyPath]) },
            set: { newValue in
                var options = windowService.configuration.options
                options[keyPath: keyPath] = CGFloat(newValue)
                windowService.updateOptions(options)
            }
        )
    }

    private func apply(_ preset: WindowLayoutPreset) {
        do {
            try windowService.apply(preset)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func arrangeWindows() {
        do {
            let count = try windowService.arrangeFocusedApplicationWindows()
            errorMessage = L("window.arranged", count)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func layoutRow(_ layout: WindowLayout) -> some View {
        HStack(spacing: 8) {
            Button {
                apply(layout)
            } label: {
                HStack(spacing: 7) {
                    WindowLayoutIcon(layout: layout)
                        .frame(width: 18, height: 14)
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
                isRecordingQuickAccessShortcut = false
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
