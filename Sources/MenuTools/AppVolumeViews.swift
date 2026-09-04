import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppVolumeCard: View {
    @Bindable var service: AppVolumeService
    let openDetails: () -> Void

    private var visibleSessions: [AppAudioSession] {
        Array(service.filteredSessions.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "speaker.wave.2.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(L("volume.title"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { service.isEnabled },
                    set: { service.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .focusable(false)
                .focusEffectDisabled()
                .accessibilityLabel(L("volume.enabled"))
                Button(action: openDetails) {
                    HStack(spacing: 3) {
                        Text(L("volume.showAll"))
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .controlCenterHover(shape: AnyShape(.circle))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("volume.showAll"))
            }

            SystemOutputVolumeRow(service: service, compact: true)

            if visibleSessions.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.slash")
                        .foregroundStyle(.secondary)
                    Text(L("volume.empty"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
            } else {
                ForEach(visibleSessions) { session in
                    AppVolumeRow(service: service, session: session, compact: true)
                }
            }

            if service.filteredSessions.count > visibleSessions.count {
                Button(action: openDetails) {
                    HStack {
                        Text(L("volume.more", service.filteredSessions.count - visibleSessions.count))
                        Spacer()
                        Image(systemName: "ellipsis.circle")
                    }
                    .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if let errorMessage = service.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCenterSurface(tint: .cyan)
    }
}

enum AppVolumeQuickAccessLayout {
    static func displayedSessions(from sessions: [AppAudioSession]) -> [AppAudioSession] {
        sessions
    }
}

enum AppVolumeRowInteractionPolicy {
    static func canAdjust(isEnabled: Bool) -> Bool {
        isEnabled
    }
}

enum AppVolumeSystemRowLayout {
    static let expandedControlHeight: CGFloat = 32
}

enum AppVolumeIconPolicy {
    static func symbolName(volume: Double, isMuted: Bool) -> String {
        guard !isMuted, volume.isFinite, volume > 0 else {
            return "speaker.slash.fill"
        }
        if volume < 1.0 / 3.0 {
            return "speaker.wave.1.fill"
        }
        if volume < 2.0 / 3.0 {
            return "speaker.wave.2.fill"
        }
        return "speaker.wave.3.fill"
    }
}

/// 可由全局快捷键直接唤起的紧凑音量管理面板。
struct AppVolumeQuickAccessView: View {
    @State private var service = AppVolumeService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "speaker.wave.2.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(L("volume.title"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { service.isEnabled },
                    set: { service.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .focusable(false)
                .focusEffectDisabled()
                .accessibilityLabel(L("volume.enabled"))
            }

            SystemOutputVolumeRow(service: service, compact: true)

            Divider()

            if service.filteredSessions.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.slash")
                        .foregroundStyle(.secondary)
                    Text(L("volume.empty"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 3)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(AppVolumeQuickAccessLayout.displayedSessions(from: service.filteredSessions)) { session in
                            AppVolumeRow(service: service, session: session, compact: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.automatic)
            }

            if let errorMessage = service.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 300, height: 360, alignment: .top)
    }
}

struct AppVolumeSettingsView: View {
    @State private var service = AppVolumeService.shared
    @State private var shortcutService = AppVolumeShortcutService.shared
    @State private var recordingShortcutAction: AppVolumeShortcutAction?
    @State private var capturedShortcut: GlobalShortcut?
    @State private var capturedShortcutAction: AppVolumeShortcutAction?
    @State private var shortcutError: String?
    @State private var presetName = ""
    @State private var presetAppIdentifiers: Set<String> = []
    @State private var isImportingPresets = false
    @State private var isExportingPresets = false
    @State private var presetDocument: AppVolumePresetDocument?
    @State private var presetTransferMessage: String?
    @State private var editingRule: AppVolumeAutomationRule?
    @State private var didCopyDiagnostic = false
    @State private var isInputLevelMonitoring = false

    private var activeSessions: [AppAudioSession] {
        service.filteredSessions.filter(\.isRunningOutput)
    }

    private var rememberedSessions: [AppAudioSession] {
        service.filteredSessions.filter { !$0.isRunningOutput }
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("volume.enabled"))
                        Text(L("volume.enabled.desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: Binding(
                        get: { service.isEnabled },
                        set: { service.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .accessibilityLabel(L("volume.enabled"))
                }

                if service.permissionState == .denied {
                    LabeledContent(L("volume.permission.status")) {
                        HStack(spacing: 8) {
                            Text(L("volume.permission.denied"))
                                .foregroundStyle(.orange)
                            Button(L("volume.openSettings"), action: openSystemSettings)
                        }
                    }
                } else if service.permissionState == .notRequested {
                    LabeledContent(
                        L("volume.permission.status"),
                        value: L("volume.permission.pending")
                    )
                } else {
                    LabeledContent(L("volume.permission.status")) {
                        Label(L("volume.permission.authorized"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Button(L("volume.resetAll"), role: .destructive) {
                    service.resetAllProfiles()
                }
                .disabled(!service.hasProfiles)

                if !shortcutService.isAccessibilityTrusted {
                    LabeledContent(L("volume.shortcut")) {
                        HStack(spacing: 8) {
                            Label(L("shortcut.permission"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button(L("shortcut.openPermission"), action: openAccessibilitySettings)
                        }
                    }
                }

                Picker(L("volume.filter"), selection: Binding(
                    get: { service.sessionFilter },
                    set: { service.setSessionFilter($0) }
                )) {
                    ForEach(AppVolumeSessionFilter.allCases, id: \.self) { filter in
                        Text(L("volume.filter.\(filter.rawValue)")).tag(filter)
                    }
                }

                Picker(L("volume.step"), selection: Binding(
                    get: { service.volumeStep },
                    set: { service.setVolumeStep($0) }
                )) {
                    Text("1%").tag(0.01)
                    Text("5%").tag(0.05)
                    Text("10%").tag(0.1)
                    Text("15%").tag(0.15)
                }

                Toggle(L("volume.boost"), isOn: Binding(
                    get: { service.isBoostEnabled },
                    set: { service.setBoostEnabled($0) }
                ))

                Text("macOS 媒体键由系统保留；请为音量操作设置带修饰键的自定义快捷键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(AppVolumeShortcutAction.allCases) { action in
                    volumeShortcutControl(for: action)
                }
            } header: {
                Label(L("volume.section.control"), systemImage: "waveform.badge.magnifyingglass")
            }

            Section {
                SystemOutputVolumeRow(service: service, compact: false)
            } header: {
                Label(L("volume.section.output"), systemImage: "speaker.wave.2")
            }

            Section {
                SystemInputVolumeRow(service: service)

                Toggle(L("volume.input.liveLevel"), isOn: $isInputLevelMonitoring)
                    .onChange(of: isInputLevelMonitoring) { _, isEnabled in
                        if isEnabled {
                            service.startInputLevelMonitoring()
                        } else {
                            service.stopInputLevelMonitoring()
                        }
                    }

                Button("会议前一键检查") {
                    _ = service.runMeetingAudioCheck()
                }
                if let meetingCheck = service.meetingCheck {
                    Label(
                        meetingCheck.isReady ? "输入和输出设备已就绪" : "请检查麦克风权限、静音状态或设备连接",
                        systemImage: meetingCheck.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(meetingCheck.isReady ? .green : .orange)
                }
            } header: {
                Label(L("volume.section.input"), systemImage: "mic")
            }

            Section {
                HStack(spacing: 10) {
                    TextField("搜索 App", text: Binding(
                        get: { service.searchQuery },
                        set: { service.setSearchQuery($0) }
                    ))
                    Picker("分组", selection: Binding(
                        get: { service.appGroupFilter },
                        set: { service.setAppGroupFilter($0) }
                    )) {
                        Text("全部").tag(nil as AppVolumeAppGroup?)
                        ForEach(AppVolumeAppGroup.allCases, id: \.self) { group in
                            Text(L(group.titleKey)).tag(group as AppVolumeAppGroup?)
                        }
                    }
                    .labelsHidden()
                    Picker("排序", selection: Binding(
                        get: { service.sessionSort },
                        set: { service.setSessionSort($0) }
                    )) {
                        ForEach(AppVolumeSessionSort.allCases, id: \.self) { sort in
                            Text(L(sort.titleKey)).tag(sort)
                        }
                    }
                    .labelsHidden()
                }
                HStack {
                    Button("静音当前列表", action: service.muteFilteredSessions)
                    Button("恢复当前列表", action: service.restoreFilteredSessions)
                }
                if activeSessions.isEmpty {
                    Text(L("volume.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeSessions) { session in
                        AppVolumeRow(service: service, session: session, compact: false)
                    }
                }
            } header: {
                Label(L("volume.section.active"), systemImage: "waveform")
            }

            if !rememberedSessions.isEmpty {
                Section {
                    ForEach(rememberedSessions) { session in
                        AppVolumeRow(service: service, session: session, compact: false)
                    }
                } header: {
                    Label(L("volume.section.remembered"), systemImage: "clock.arrow.circlepath")
                }
            }

            Section {
                HStack {
                    Text("最大主音量")
                    Slider(value: Binding(
                        get: { service.masterVolumeLimit },
                        set: { service.setMasterVolumeLimit($0) }
                    ), in: 0.1...1)
                    Text("\(Int((service.masterVolumeLimit * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Toggle("耳机连接时自动应用上限", isOn: Binding(
                    get: { service.limitsHeadphoneVolume },
                    set: { service.setLimitsHeadphoneVolume($0) }
                ))
                if let warning = service.hearingWarningMessage {
                    HStack {
                        Label(warning, systemImage: "ear.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("知道了", action: service.dismissHearingWarning)
                    }
                }
            } header: {
                Label("听力保护", systemImage: "ear")
            }

            Section {
                Toggle("会议时压低其他正在发声的 App", isOn: Binding(
                    get: { service.meetingDuckingEnabled },
                    set: { service.setMeetingDuckingEnabled($0) }
                ))
                HStack {
                    Text("保留音量")
                    Slider(value: Binding(
                        get: { service.meetingDuckingFactor },
                        set: { service.setMeetingDuckingFactor($0) }
                    ), in: 0.1...0.8)
                    Text("\(Int((service.meetingDuckingFactor * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if service.isMeetingDuckingActive {
                    Label("会议音频进行中，其他 App 已临时压低", systemImage: "person.2.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            } header: {
                Label("会议智能压低", systemImage: "person.2.wave.2")
            }

            Section {
                HStack {
                    TextField(L("volume.preset.name"), text: $presetName)
                    Menu("包含 \(presetAppIdentifiers.count == 0 ? service.sessions.count : presetAppIdentifiers.count) 个 App") {
                        ForEach(service.sessions) { session in
                            Toggle(session.displayName, isOn: Binding(
                                get: { presetAppIdentifiers.isEmpty || presetAppIdentifiers.contains(session.id) },
                                set: { enabled in
                                    if presetAppIdentifiers.isEmpty {
                                        presetAppIdentifiers = Set(service.sessions.map(\.id))
                                    }
                                    if enabled { presetAppIdentifiers.insert(session.id) }
                                    else { presetAppIdentifiers.remove(session.id) }
                                }
                            ))
                        }
                    }
                    Button(L("volume.preset.save")) {
                        let identifiers = presetAppIdentifiers.isEmpty ? Set(service.sessions.map(\.id)) : presetAppIdentifiers
                        let levels = Dictionary(uniqueKeysWithValues: service.sessions.compactMap { session in
                            identifiers.contains(session.id) ? (session.id, session.volume) : nil
                        })
                        _ = service.savePreset(named: presetName, appVolumes: levels)
                        presetName = ""
                    }
                    .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    Button("导入预设") {
                        presetTransferMessage = nil
                        isImportingPresets = true
                    }
                    Button("导出预设") {
                        presetDocument = service.exportPresets().map(AppVolumePresetDocument.init)
                        isExportingPresets = presetDocument != nil
                    }
                    .disabled(service.presets.isEmpty)
                }
                if let presetTransferMessage {
                    Text(presetTransferMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Picker("当前输出设备自动预设", selection: Binding(
                    get: { service.boundPresetID(forOutputDeviceUID: service.output.deviceUID) },
                    set: { service.bindPreset($0, toOutputDeviceUID: service.output.deviceUID) }
                )) {
                    Text("不自动应用").tag(nil as UUID?)
                    ForEach(service.presets) { preset in
                        Text(preset.name).tag(preset.id as UUID?)
                    }
                }
                .disabled(service.output.deviceUID.isEmpty || service.presets.isEmpty)

                ForEach(service.presets) { preset in
                    HStack {
                        TextField("预设名称", text: Binding(
                            get: { service.presets.first(where: { $0.id == preset.id })?.name ?? preset.name },
                            set: { service.renamePreset(id: preset.id, to: $0) }
                        ))
                        Spacer()
                        Button(L("volume.preset.apply")) {
                            service.applyPreset(id: preset.id)
                        }
                        Menu {
                            Button(L("volume.automation.add")) {
                                service.addAutomationRule(
                                    presetID: preset.id,
                                    outputDeviceUID: service.output.deviceUID.isEmpty ? nil : service.output.deviceUID
                                )
                            }
                            Button("覆盖当前配置") {
                                service.overwritePreset(id: preset.id)
                            }
                            Button(L("volume.preset.delete"), role: .destructive) {
                                service.deletePreset(id: preset.id)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                    }
                }
            } header: {
                Label(L("volume.section.presets"), systemImage: "slider.horizontal.3")
            }

            if !service.automationRules.isEmpty {
                Section {
                    ForEach(service.automationRules) { rule in
                        HStack {
                            Text(service.presets.first(where: { $0.id == rule.presetID })?.name ?? L("volume.preset.unnamed"))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { rule.isEnabled },
                                set: { service.setAutomationRuleEnabled($0, id: rule.id) }
                            ))
                            .labelsHidden()
                            Button {
                                editingRule = rule
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .buttonStyle(.plain)
                            Button(role: .destructive) {
                                service.deleteAutomationRule(id: rule.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Label(L("volume.section.automation"), systemImage: "wand.and.stars")
                } footer: {
                    Text(L("volume.automation.desc"))
                }
            }

            if !service.automationExecutions.isEmpty {
                Section {
                    if service.canUndoLatestAutomation {
                        Button("撤销最近一次自动化") {
                            service.undoLatestAutomation()
                        }
                    }
                    ForEach(service.automationExecutions) { execution in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(execution.presetName) · \(execution.outputDeviceName)")
                            Text(execution.executedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if execution.revertedAt != nil {
                                Text("已撤销")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    Label("自动化执行记录", systemImage: "clock.arrow.circlepath")
                } footer: {
                    Text("仅保留最近 20 条记录；可撤销本次运行期间最近一次自动化。")
                }
            }

            if let errorMessage = service.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button(didCopyDiagnostic ? "诊断报告已复制" : "复制兼容性诊断报告") {
                    didCopyDiagnostic = service.copyDiagnosticReport()
                }
                Text("报告包含权限、输入输出设备、路由失败及 DRM/Process Tap 兼容性信息。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("兼容性诊断", systemImage: "stethoscope")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            shortcutService.refreshAccessibilityTrust()
            service.refreshOutputDevices()
            service.refreshInputDevices()
        }
        .onDisappear {
            service.stopInputLevelMonitoring()
        }
        .fileImporter(isPresented: $isImportingPresets, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let data = try Data(contentsOf: url)
                try service.importPresets(from: data)
                presetTransferMessage = "预设导入完成"
            } catch {
                presetTransferMessage = "预设导入失败：\(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $isExportingPresets,
            document: presetDocument,
            contentType: .json,
            defaultFilename: "MenuTools 音量预设"
        ) { result in
            if case let .failure(error) = result {
                presetTransferMessage = "预设导出失败：\(error.localizedDescription)"
            }
        }
        .sheet(item: $editingRule) { rule in
            AppVolumeAutomationRuleEditor(
                rule: rule,
                outputDevices: service.outputDevices,
                onSave: service.updateAutomationRule
            )
        }
        .overlay {
            GlobalShortcutCaptureView(isRecording: recordingShortcutAction != nil) { shortcut in
                let action = recordingShortcutAction
                recordingShortcutAction = nil
                guard let shortcut else { return }
                capturedShortcut = shortcut
                capturedShortcutAction = action
                shortcutError = nil
            }
            .frame(width: 1, height: 1)
        }
    }

    private func volumeShortcutControl(for action: AppVolumeShortcutAction) -> some View {
        LabeledContent(L(action.titleKey)) {
            HStack(spacing: 8) {
                Text(
                    recordingShortcutAction == action
                        ? L("settings.recording")
                        : capturedShortcutAction == action
                            ? capturedShortcut?.displayName ?? L("settings.unset")
                            : shortcutService.bindings[action]?.displayName ?? L("settings.unset")
                )
                .font(.callout.monospaced())
                .foregroundStyle(
                    recordingShortcutAction == action || capturedShortcutAction == action || shortcutService.bindings[action] != nil
                        ? .primary : .secondary
                )

                if capturedShortcutAction == action, capturedShortcut != nil {
                    Button(L("volume.shortcutSave")) {
                        saveShortcut(for: action)
                    }
                }

                Button {
                    capturedShortcut = nil
                    capturedShortcutAction = nil
                    shortcutError = nil
                    recordingShortcutAction = recordingShortcutAction == action ? nil : action
                } label: {
                    Image(systemName: recordingShortcutAction == action ? "xmark" : "record.circle")
                }
                .help(recordingShortcutAction == action ? L("settings.recording") : L("shortcut.record"))

                if shortcutService.bindings[action] != nil, recordingShortcutAction != action {
                    Button {
                        shortcutService.clearBinding(for: action)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(L("shortcut.clear"))
                }
            }
        }
        .help(L("volume.shortcutDescription"))
        .overlay(alignment: .bottomLeading) {
            if let shortcutError {
                Text(shortcutError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .offset(y: 16)
            }
        }
        .padding(.bottom, shortcutError == nil ? 0 : 14)
    }

    private func saveShortcut(for action: AppVolumeShortcutAction) {
        guard let capturedShortcut else { return }
        do {
            try shortcutService.setBinding(capturedShortcut, for: action)
            self.capturedShortcut = nil
            capturedShortcutAction = nil
            shortcutError = nil
        } catch {
            shortcutError = error.localizedDescription
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct AppVolumePresetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(_ data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct AppVolumeAutomationRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: AppVolumeAutomationRule
    @State private var useTimeRange: Bool
    @State private var startMinute: String
    @State private var endMinute: String
    @State private var focusModeRequirement: Int

    let outputDevices: [AudioOutputDevice]
    let onSave: (AppVolumeAutomationRule) -> Void

    init(
        rule: AppVolumeAutomationRule,
        outputDevices: [AudioOutputDevice],
        onSave: @escaping (AppVolumeAutomationRule) -> Void
    ) {
        self.rule = rule
        self.outputDevices = outputDevices
        self.onSave = onSave
        _useTimeRange = State(initialValue: rule.startMinute != nil && rule.endMinute != nil)
        _startMinute = State(initialValue: Self.timeText(rule.startMinute))
        _endMinute = State(initialValue: Self.timeText(rule.endMinute))
        _focusModeRequirement = State(initialValue: rule.requiresFocusMode == nil ? 0 : rule.requiresFocusMode == true ? 1 : 2)
    }

    var body: some View {
        Form {
            Picker("输出设备", selection: $rule.outputDeviceUID) {
                Text("任意输出设备").tag(nil as String?)
                ForEach(outputDevices) { device in
                    Text(device.name).tag(device.uid as String?)
                }
            }
            Toggle("启用时间段", isOn: $useTimeRange)
            if useTimeRange {
                TextField("开始时间（HH:mm）", text: $startMinute)
                TextField("结束时间（HH:mm）", text: $endMinute)
            }
            Picker("专注模式", selection: $focusModeRequirement) {
                Text("不限制").tag(0)
                Text("必须开启").tag(1)
                Text("必须关闭").tag(2)
            }
            TextField("前台 App Bundle ID", text: Binding(
                get: { rule.launchBundleID ?? "" },
                set: { rule.launchBundleID = $0 }
            ))
            TextField("Wi-Fi 名称", text: Binding(
                get: { rule.wifiName ?? "" },
                set: { rule.wifiName = $0 }
            ))
        }
        .padding()
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", action: dismiss.callAsFunction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    rule.requiresFocusMode = switch focusModeRequirement {
                    case 1: true
                    case 2: false
                    default: nil
                    }
                    let range = useTimeRange ? (Self.minute(from: startMinute), Self.minute(from: endMinute)) : (nil, nil)
                    rule.startMinute = range.0
                    rule.endMinute = range.1
                    onSave(rule)
                    dismiss()
                }
            }
        }
    }

    private static func minute(from value: String) -> Int? {
        let components = value.split(separator: ":").compactMap { Int($0) }
        guard components.count == 2, (0..<24).contains(components[0]), (0..<60).contains(components[1]) else { return nil }
        return components[0] * 60 + components[1]
    }

    private static func timeText(_ minute: Int?) -> String {
        guard let minute else { return "" }
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

private struct SystemOutputVolumeRow: View {
    @Bindable var service: AppVolumeService
    let compact: Bool

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 7 : 10) {
            Button {
                service.setMasterMuted(!service.output.isMuted)
            } label: {
                Image(systemName: AppVolumeIconPolicy.symbolName(
                    volume: service.output.volume,
                    isMuted: service.output.isMuted
                ))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: compact ? 18 : 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(service.output.isMuted ? Color.orange : Color.accentColor)
            .disabled(!service.output.canSetMute)
            .accessibilityLabel(L("volume.mute"))
            .frame(height: controlHeight)

            Menu {
                if service.outputDevices.isEmpty {
                    Text(L("volume.output.none"))
                } else {
                    ForEach(service.outputDevices) { device in
                        Button {
                            service.selectOutputDevice(device)
                        } label: {
                            Label(device.name, systemImage: device.isDefault ? "checkmark" : "speaker.wave.2")
                        }
                    }
                }
            } label: {
                Image(systemName: "airplayaudio")
                    .frame(width: compact ? 14 : 18)
            }
            .menuStyle(.borderlessButton)
            .focusable(false)
            .focusEffectDisabled()
            .help(L("volume.output.select"))
            .frame(height: controlHeight)

            if compact {
                VStack(alignment: .leading, spacing: 3) {
                    outputDeviceName
                    volumeSlider
                }
            } else {
                outputDeviceName
                    .frame(width: 155, height: controlHeight, alignment: .leading)
                volumeSlider
                    .frame(height: controlHeight)
                    .layoutPriority(1)
                if !service.output.canSetVolume {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(L("volume.output.fixed"))
                        .frame(height: controlHeight)
                }
            }

            Text("\(Int((service.output.volume * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, height: controlHeight, alignment: .trailing)
        }
    }

    private var controlHeight: CGFloat? {
        compact ? nil : AppVolumeSystemRowLayout.expandedControlHeight
    }

    private var outputDeviceName: some View {
        Text(service.output.deviceName.isEmpty ? L("volume.output.unknown") : service.output.deviceName)
            .font(compact ? .caption2 : .caption)
            .foregroundStyle(compact ? .secondary : .primary)
            .lineLimit(1)
    }

    private var volumeSlider: some View {
        Slider(value: Binding(
            get: { service.output.volume },
            set: { service.setMasterVolume($0) }
        ), in: 0...1)
        .disabled(!service.output.canSetVolume)
        .accessibilityLabel(L("volume.master"))
    }
}

private struct SystemInputVolumeRow: View {
    @Bindable var service: AppVolumeService

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                service.setInputMuted(!service.input.isMuted)
            } label: {
                Image(systemName: service.input.isMuted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(service.input.isMuted ? Color.orange : Color.accentColor)
            .disabled(!service.input.canSetMute)
            .accessibilityLabel(L("volume.muteInput"))
            .frame(height: AppVolumeSystemRowLayout.expandedControlHeight)

            Menu {
                ForEach(service.inputDevices) { device in
                    Button(device.name) { service.selectInputDevice(device) }
                }
            } label: {
                Image(systemName: "mic.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .frame(height: AppVolumeSystemRowLayout.expandedControlHeight)

            Text(service.input.deviceName.isEmpty ? L("volume.input.unknown") : service.input.deviceName)
                .font(.caption)
                .lineLimit(1)
                .frame(
                    width: 155,
                    height: AppVolumeSystemRowLayout.expandedControlHeight,
                    alignment: .leading
                )

            Slider(value: Binding(
                get: { service.input.volume },
                set: { service.setInputVolume($0) }
            ), in: 0...1)
            .disabled(!service.input.canSetVolume)
            .accessibilityLabel(L("volume.input"))
            .frame(height: AppVolumeSystemRowLayout.expandedControlHeight)
            .layoutPriority(1)

            if !service.input.canSetVolume {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(L("volume.input.fixed"))
                    .frame(height: AppVolumeSystemRowLayout.expandedControlHeight)
            }

            Text("\(Int((service.input.volume * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(
                    width: 34,
                    height: AppVolumeSystemRowLayout.expandedControlHeight,
                    alignment: .trailing
                )

            VStack(spacing: 2) {
                ProgressView(value: service.input.peakLevel)
                    .progressViewStyle(.linear)
                    .frame(width: 36)
                Text("\(Int((service.input.peakLevel * 100).rounded()))")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("麦克风实时输入电平")
        }
    }
}

private struct AppVolumeRow: View {
    @Bindable var service: AppVolumeService
    let session: AppAudioSession
    let compact: Bool
    @State private var showsEqualizer = false

    var body: some View {
        HStack(spacing: compact ? 7 : 10) {
            appIcon
                .frame(width: compact ? 18 : 26, height: compact ? 18 : 26)

            if compact {
                compactControls
            } else {
                HStack(spacing: 5) {
                    Text(session.displayName)
                        .font(.caption)
                        .lineLimit(1)
                    if session.isRunningOutput {
                        Circle()
                            .fill(.green)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel(L("volume.active"))
                    }
                    if session.errorMessage != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        service.toggleFavorite(for: session.rootBundleID)
                    } label: {
                        Image(systemName: session.isFavorite ? "star.fill" : "star")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(session.isFavorite ? .yellow : .secondary)
                    .accessibilityLabel(L("volume.favorite", session.displayName))
                    Menu {
                        ForEach(AppVolumeAppGroup.allCases, id: \.self) { group in
                            Button(L(group.titleKey)) {
                                service.setAppGroup(group, for: session.rootBundleID)
                            }
                        }
                    } label: {
                        Image(systemName: "folder")
                            .font(.caption2)
                    }
                    .menuStyle(.borderlessButton)
                    .help("分组：\(L(session.appGroup.titleKey))")
                    Button {
                        showsEqualizer = true
                    } label: {
                        Image(systemName: "slider.vertical.3")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                    .foregroundStyle(session.equalizer.requiresProcessing ? Color.accentColor : Color.secondary)
                    .help(L("volume.equalizer"))
                    .popover(isPresented: $showsEqualizer, arrowEdge: .trailing) {
                        AppVolumeEqualizerEditor(
                            service: service,
                            rootBundleID: session.rootBundleID
                        )
                    }
                }
                .frame(width: 200, alignment: .leading)

                Slider(value: Binding(
                    get: { service.session(id: session.rootBundleID)?.volume ?? session.volume },
                    set: { service.setVolume($0, for: session.rootBundleID) }
                ), in: 0...service.maximumAppGain)
                .disabled(!AppVolumeRowInteractionPolicy.canAdjust(isEnabled: service.isEnabled))
                .accessibilityLabel(L("volume.app", session.displayName))
            }

            Button {
                service.toggleMute(for: session.rootBundleID)
            } label: {
                Image(systemName: AppVolumeIconPolicy.symbolName(
                    volume: session.volume,
                    isMuted: session.volume == 0
                ))
                    .font(.caption)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .foregroundStyle(session.volume == 0 ? .orange : .secondary)
            .disabled(!AppVolumeRowInteractionPolicy.canAdjust(isEnabled: service.isEnabled))
            .accessibilityLabel(L("volume.muteApp", session.displayName))

            Text("\(Int((session.volume * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)

            if !compact {
                VStack(spacing: 2) {
                    ProgressView(value: session.meter.heldPeak)
                        .progressViewStyle(.linear)
                        .frame(width: 36)
                    Text("P\(Int((session.meter.peak * 100).rounded())) R\(Int((session.meter.rms * 100).rounded()))")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(session.meter.isClipping ? .red : .secondary)
                }
                .accessibilityLabel("\(session.displayName) 的 Peak、RMS 与保持峰值")

                Image(systemName: routeStatusSymbol)
                    .font(.caption2)
                    .foregroundStyle(routeStatusColor)
                    .help("路由状态，CPU \(Int((session.meter.cpuLoad * 100).rounded()))%")

                if session.errorMessage != nil {
                    Button {
                        service.retryRoute(for: session.rootBundleID)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help(L("volume.retry"))

                    Button {
                        service.bypassRoute(for: session.rootBundleID)
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .buttonStyle(.plain)
                    .help(L("volume.bypass"))
                }
                Button {
                    service.resetProfile(for: session.rootBundleID)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("volume.resetApp", session.displayName))
            }
        }
    }

    private var compactControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(session.displayName)
                    .font(.caption2)
                    .lineLimit(1)
                if session.isRunningOutput {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel(L("volume.active"))
                }
                if session.errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Button {
                    showsEqualizer = true
                } label: {
                    Image(systemName: "slider.vertical.3")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .foregroundStyle(session.equalizer.requiresProcessing ? Color.accentColor : Color.secondary)
                .accessibilityLabel(L("volume.equalizer"))
                .popover(isPresented: $showsEqualizer, arrowEdge: .trailing) {
                    AppVolumeEqualizerEditor(
                        service: service,
                        rootBundleID: session.rootBundleID
                    )
                }
            }
            Slider(value: Binding(
                get: { service.session(id: session.rootBundleID)?.volume ?? session.volume },
                set: { service.setVolume($0, for: session.rootBundleID) }
            ), in: 0...service.maximumAppGain)
            .disabled(!AppVolumeRowInteractionPolicy.canAdjust(isEnabled: service.isEnabled))
            .accessibilityLabel(L("volume.app", session.displayName))
        }
    }

    private var routeStatusSymbol: String {
        switch session.routeStatus {
        case .active: "point.3.connected.trianglepath.dotted"
        case .bypassed: "arrow.uturn.forward"
        case .failed: "exclamationmark.triangle.fill"
        case .unavailable: "questionmark.circle"
        }
    }

    private var routeStatusColor: Color {
        switch session.routeStatus {
        case .active: .green
        case .bypassed: .secondary
        case .failed: .red
        case .unavailable: .orange
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let bundleURL = session.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: session.rootBundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundleURL.path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct AppVolumeEqualizerEditor: View {
    @Bindable var service: AppVolumeService
    let rootBundleID: String
    @State private var showsPresetPicker = false
    @State private var showsOutputPicker = false

    private var session: AppAudioSession? {
        service.session(id: rootBundleID)
    }

    private var equalizer: AppVolumeEqualizer {
        session?.equalizer ?? .flat
    }

    private var selectedOutputName: String {
        guard let outputDeviceUID = session?.outputDeviceUID else {
            return L("volume.output.system")
        }
        return service.outputDevices.first(where: { $0.uid == outputDeviceUID })?.name
            ?? L("volume.output.unavailable")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(session?.displayName ?? L("volume.equalizer"), systemImage: "slider.vertical.3")
                    .font(.headline)
                Spacer()
                AppVolumeEqualizerToggle(
                    isEnabled: equalizer.isEnabled,
                    action: { service.setEqualizerEnabled(!equalizer.isEnabled, for: rootBundleID) }
                )
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    controlLabel(L("volume.equalizer.preset"), systemImage: "slider.horizontal.3")
                    Button {
                        showsOutputPicker = false
                        showsPresetPicker.toggle()
                    } label: {
                        pickerLabel(
                            L(equalizer.matchingPreset?.titleKey ?? "volume.equalizer.custom"),
                            isExpanded: showsPresetPicker
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusable(false)
                    .focusEffectDisabled()
                    .popover(isPresented: $showsPresetPicker, arrowEdge: .bottom) {
                        presetPicker
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    controlLabel(L("volume.output.select"), systemImage: "airplayaudio")
                    Button {
                        showsPresetPicker = false
                        showsOutputPicker.toggle()
                    } label: {
                        pickerLabel(selectedOutputName, isExpanded: showsOutputPicker)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusable(false)
                    .focusEffectDisabled()
                    .popover(isPresented: $showsOutputPicker, arrowEdge: .bottom) {
                        outputPicker
                    }
                }
            }
            .font(.caption)
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(spacing: 10) {
                HStack {
                    Text("−12 dB")
                    Spacer()
                    Text("0 dB")
                    Spacer()
                    Text("+12 dB")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(AppVolumeEqualizer.bandFrequencies.indices, id: \.self) { index in
                        AppVolumeEqualizerBandControl(
                            frequency: AppVolumeEqualizer.bandFrequencies[index],
                            value: equalizer.gain(at: index)
                        ) { value in
                            service.setEqualizerGain(value, at: index, for: rootBundleID)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(14)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(18)
        .frame(width: 500)
        .background(.regularMaterial)
        .onAppear {
            service.refreshOutputDevices()
        }
    }

    private func controlLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func pickerLabel(_ title: String, isExpanded: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2.weight(.semibold))
        }
    }

    private var presetPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(AppVolumeEqualizerPreset.allCases, id: \.self) { preset in
                    Button {
                        service.setEqualizerPreset(preset, for: rootBundleID)
                        showsPresetPicker = false
                    } label: {
                        HStack {
                            Text(L(preset.titleKey))
                            Spacer()
                            if equalizer.matchingPreset == preset {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
            }
            .padding(6)
        }
        .frame(width: 190, height: 250)
    }

    private var outputPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                outputPickerButton(title: L("volume.output.system"), device: nil)
                if !service.outputDevices.isEmpty { Divider().padding(.vertical, 4) }
                ForEach(service.outputDevices) { device in
                    outputPickerButton(title: device.name, device: device)
                }
            }
            .padding(6)
        }
        .frame(width: 240, height: 220)
    }

    private func outputPickerButton(title: String, device: AudioOutputDevice?) -> some View {
        Button {
            service.setOutputDevice(device, for: rootBundleID)
            showsOutputPicker = false
        } label: {
            HStack {
                Image(systemName: device == nil ? "globe" : "speaker.wave.2")
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                Spacer()
                if session?.outputDeviceUID == device?.uid || (device == nil && session?.outputDeviceUID == nil) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct AppVolumeEqualizerToggle: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isEnabled ? .trailing : .leading) {
                Capsule()
                    .fill(isEnabled ? Color.accentColor : Color.secondary.opacity(0.28))
                Capsule()
                    .fill(.white.opacity(0.96))
                    .frame(width: 19, height: 18)
                    .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
                    .padding(2)
            }
            .frame(width: 42, height: 22)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .animation(.easeInOut(duration: 0.16), value: isEnabled)
        .accessibilityLabel(L("volume.equalizer.enabled"))
    }
}

private struct AppVolumeEqualizerBandControl: View {
    let frequency: Double
    let value: Double
    let onChange: (Double) -> Void

    private var progress: Double {
        (value - AppVolumeEqualizer.minimumGain)
            / (AppVolumeEqualizer.maximumGain - AppVolumeEqualizer.minimumGain)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(gainName)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(value == 0 ? .secondary : .primary)
                .frame(height: 14)
            GeometryReader { proxy in
                let inset = 7.0
                let trackHeight = max(proxy.size.height - inset * 2, 1)
                let knobY = inset + (1 - progress) * trackHeight
                ZStack {
                    Capsule()
                        .fill(.tertiary)
                        .frame(width: 4)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 4, height: max(trackHeight * progress, 2))
                    }
                    Circle()
                        .fill(.background)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(value == 0 ? Color.secondary.opacity(0.45) : Color.accentColor, lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
                        .position(x: proxy.size.width / 2, y: knobY)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let nextProgress = min(max((proxy.size.height - inset - gesture.location.y) / trackHeight, 0), 1)
                            onChange(AppVolumeEqualizer.minimumGain
                                + nextProgress * (AppVolumeEqualizer.maximumGain - AppVolumeEqualizer.minimumGain))
                        }
                )
            }
            .frame(width: 28, height: 118)
            .accessibilityElement()
            .accessibilityLabel("\(frequencyName) Hz")
            .accessibilityValue("\(gainName) dB")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 1.0 : -1.0
                onChange(min(max(value + step, AppVolumeEqualizer.minimumGain), AppVolumeEqualizer.maximumGain))
            }
            Text(frequencyName)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: 34)
    }

    private var gainName: String {
        let gain = Int(value.rounded())
        return gain > 0 ? "+\(gain)" : "\(gain)"
    }

    private var frequencyName: String {
        frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
    }
}
