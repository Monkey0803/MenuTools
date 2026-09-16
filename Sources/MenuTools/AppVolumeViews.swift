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
        .onDisappear {
            service.setVolumeAdjustmentActive(false)
        }
    }
}

enum AppVolumeQuickAccessLayout {
    static func displayedSessions(from sessions: [AppAudioSession]) -> [AppAudioSession] {
        sessions
    }
}

/// 音量设置页的一级任务，默认进入调音台而不是配置项列表。
enum AppVolumeSettingsPage: String, CaseIterable, Identifiable {
    case mixer
    case devices
    case scenes
    case settings

    var id: Self { self }

    var titleKey: String { "volume.page.\(rawValue)" }

    var symbol: String {
        switch self {
        case .mixer: "slider.horizontal.3"
        case .devices: "hifispeaker.and.homepod"
        case .scenes: "wand.and.stars"
        case .settings: "gearshape"
        }
    }
}

/// 将服务层已筛选的会话分成“正在发声”和“已记住”，避免视图自行改变排序。
struct AppVolumeMixerContent: Equatable {
    let active: [AppAudioSession]
    let remembered: [AppAudioSession]
    let hasNarrowingFilter: Bool

    init(
        sessions: [AppAudioSession],
        searchQuery: String,
        filter: AppVolumeSessionFilter,
        group: AppVolumeAppGroup?
    ) {
        active = sessions.filter(\.isRunningOutput)
        remembered = sessions.filter { !$0.isRunningOutput }
        hasNarrowingFilter = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || filter != .all
            || group != nil
    }

    /// 已记住的 App 只有在存在、且用户展开或正在筛选时才显示。
    func showsRemembered(userExpanded: Bool) -> Bool {
        !remembered.isEmpty && (userExpanded || hasNarrowingFilter)
    }

    /// 活跃列表为空时，用于区分「没有播放中的应用」与「筛选无结果」。
    var emptyStateKey: String {
        hasNarrowingFilter ? "volume.empty.filtered" : "volume.empty.idle"
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

/// 音量预设区「新建」的展开状态。
///
/// 预设页默认只列出已有预设并摆一个「＋」入口，新建表单收起：一进预设页不该先看到一个空白
/// 新建表单，那会让人把它当成预设列表本身。收起时连名称与 App 选择一起清掉，
/// 否则上一次勾选的 App 会被悄悄带进下一个预设。
struct AppVolumePresetCreationDraft: Equatable {
    /// 新建表单是否已展开；默认收起。
    private(set) var isExpanded = false
    /// 输入中的预设名称。
    var name = ""
    /// 勾选的 App；空集表示包含当前所有 App。
    var appIdentifiers: Set<String> = []

    /// 展开且名称非空时才允许保存。
    var canSave: Bool {
        isExpanded && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 展开新建表单，并清掉上一次的残留。
    mutating func begin() {
        isExpanded = true
        name = ""
        appIdentifiers = []
    }

    /// 收起并清空；保存与取消共用同一条收尾路径。
    mutating func finish() {
        isExpanded = false
        name = ""
        appIdentifiers = []
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
    @State private var presetDraft = AppVolumePresetCreationDraft()
    @State private var isImportingPresets = false
    @State private var isExportingPresets = false
    @State private var presetDocument: AppVolumePresetDocument?
    @State private var presetTransferMessage: String?
    @State private var editingRule: AppVolumeAutomationRule?
    @State private var didCopyDiagnostic = false
    @State private var isInputLevelMonitoring = false
    @State private var channelTester = AppVolumeChannelTester.shared
    @State private var page: AppVolumeSettingsPage = .mixer
    /// 「已记住」分区由用户手动展开；有搜索/筛选时自动展开。
    @State private var showsRememberedSessions = false
    /// 低频设置（会议闪避、睡眠定时、自检与诊断）默认收起，避免设置页要滚三屏。
    @State private var showsAdvancedSettings = false
    @State private var presetSync = AppVolumePresetSyncService.shared
    @State private var presetSyncPassphrase = ""
    @State private var presetSyncConflictCopies: [URL] = []

    /// 调音台内容：服务层已经排好序，这里只做「正在发声 / 已记住」分区。
    private var mixerContent: AppVolumeMixerContent {
        AppVolumeMixerContent(
            sessions: service.filteredSessions,
            searchQuery: service.searchQuery,
            filter: service.sessionFilter,
            group: service.appGroupFilter
        )
    }

    var body: some View {
        Form {
            Section {
                Picker(L("volume.page.title"), selection: $page) {
                    ForEach(AppVolumeSettingsPage.allCases) { item in
                        Label(L(item.titleKey), systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .focusable(false)
                .focusEffectDisabled()
            }

            if page == .mixer {
            Section {
                SystemOutputVolumeRow(service: service, compact: false)

                    .foregroundStyle(.secondary)
            } header: {
                Label(L("volume.section.output"), systemImage: "speaker.wave.2")
            }

            Section {
                SystemInputVolumeRow(service: service)

            } header: {
                Label(L("volume.section.input"), systemImage: "mic")
            }

            Section {
                HStack(spacing: 10) {
                    TextField(L("volume.search.placeholder"), text: Binding(
                        get: { service.searchQuery },
                        set: { service.setSearchQuery($0) }
                    ))
                    Picker(L("volume.groupFilter"), selection: Binding(
                        get: { service.appGroupFilter },
                        set: { service.setAppGroupFilter($0) }
                    )) {
                        Text(L("volume.filter.all")).tag(nil as AppVolumeAppGroup?)
                        ForEach(AppVolumeAppGroup.allCases, id: \.self) { group in
                            Text(L(group.titleKey)).tag(group as AppVolumeAppGroup?)
                        }
                    }
                    .labelsHidden()
                    Picker(L("volume.sort"), selection: Binding(
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
                    Button(L("volume.muteFiltered"), action: service.muteFilteredSessions)
                    Button(L("volume.restoreFiltered"), action: service.restoreFilteredSessions)
                }
                Toggle(L("volume.remembered.show"), isOn: $showsRememberedSessions)
                    .font(.caption)
                    .focusable(false)
                    .focusEffectDisabled()

                if mixerContent.active.isEmpty {
                    Text(L(mixerContent.emptyStateKey))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mixerContent.active) { session in
                        AppVolumeRow(service: service, session: session, compact: false)
                    }
                }
            } header: {
                Label(L("volume.section.active"), systemImage: "waveform")
            }

            if mixerContent.showsRemembered(userExpanded: showsRememberedSessions) {
                Section {
                    ForEach(mixerContent.remembered) { session in
                        AppVolumeRow(service: service, session: session, compact: false)
                    }
                } header: {
                    Label(L("volume.section.remembered"), systemImage: "clock.arrow.circlepath")
                }
            }

            Section {
                ForEach(AppVolumeAppGroup.allCases, id: \.self) { group in
                    AppVolumeGroupVolumeRow(service: service, group: group)
                }
            } header: {
                Label(L("volume.groupVolume.title"), systemImage: "dial.medium")
            }

            } else if page == .devices {
                AppVolumeOutputDeviceSection(service: service)
                AppVolumeInputDeviceSection(service: service)

                Section {
                HStack(spacing: 8) {
                    Label(L("volume.channelTest.title"), systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach(AppVolumeChannelTester.Channel.allCases, id: \.self) { channel in
                        Button(L(channel.titleKey)) {
                            channelTester.play(channel)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .focusable(false)
                        .focusEffectDisabled()
                    }
                    if channelTester.isPlaying {
                        Button(L("volume.channelTest.stop")) {
                            channelTester.stop()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .focusable(false)
                        .focusEffectDisabled()
                    }
                }

                Text(L("volume.channelTest.desc"))
                    .font(.caption)
                } header: {
                    Label(L("volume.channelTest.title"), systemImage: "waveform")
                }

                Section {
                Toggle(L("volume.input.liveLevel"), isOn: $isInputLevelMonitoring)
                    .onChange(of: isInputLevelMonitoring) { _, isEnabled in
                        if isEnabled {
                            service.startInputLevelMonitoring()
                        } else {
                            service.stopInputLevelMonitoring()
                        }
                    }

                Text(L("volume.input.liveLevel.desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(L("volume.meeting.check")) {
                    _ = service.runMeetingAudioCheck()
                }
                if let meetingCheck = service.meetingCheck {
                    Label(
                        meetingCheck.isReady ? L("volume.meeting.ready") : L("volume.meeting.attention"),
                        systemImage: meetingCheck.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(meetingCheck.isReady ? .green : .orange)
                }
                } header: {
                    Label(L("volume.input.monitor.title"), systemImage: "waveform.badge.mic")
                }
            } else if page == .scenes {
            Section {
                presetCreationRow

                if service.presets.isEmpty {
                    Text(L("volume.preset.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(service.presets) { preset in
                        VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField(L("volume.preset.name"), text: Binding(
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
                                Button(L("volume.preset.overwrite")) {
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
                        HStack(spacing: 6) {
                            Text(L("volume.preset.coverage", preset.appVolumes.count, preset.appSettings.count))
                            let boundDevices = service.boundDeviceNames(forPresetID: preset.id)
                            if !boundDevices.isEmpty {
                                Text(L("volume.preset.binding.devices", boundDevices.joined(separator: "、")))
                            }
                            if preset.needsCoverageUpgrade {
                                Label(L("volume.preset.coverageHint"), systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Button(L("volume.preset.import")) {
                        presetTransferMessage = nil
                        isImportingPresets = true
                    }
                    Button(L("volume.preset.export")) {
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
                Picker(L("volume.preset.bindToOutput"), selection: Binding(
                    get: { service.boundPresetID(forOutputDeviceUID: service.output.deviceUID) },
                    set: { service.bindPreset($0, toOutputDeviceUID: service.output.deviceUID) }
                )) {
                    Text(L("volume.preset.none")).tag(nil as UUID?)
                    ForEach(service.presets) { preset in
                        Text(preset.name).tag(preset.id as UUID?)
                    }
                }
                .disabled(service.output.deviceUID.isEmpty || service.presets.isEmpty)

                ForEach(service.presetBindings) { binding in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Image(systemName: binding.isDeviceAvailable ? "hifispeaker.fill" : "questionmark.circle")
                                .foregroundStyle(binding.isDeviceAvailable ? Color.secondary : Color.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(binding.deviceName ?? L("volume.preset.binding.unknownDevice"))
                                    .lineLimit(1)
                                Text(binding.presetName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(L("volume.preset.binding.clear")) {
                                service.clearPresetBinding(forOutputDeviceUID: binding.deviceUID)
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .focusable(false)
                            .focusEffectDisabled()
                        }
                        if !binding.isDeviceAvailable {
                            Text(L("volume.preset.binding.missingHint"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
                        Button(L("volume.automation.undoLatest")) {
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
                                Text(L("volume.automation.reverted"))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    Label(L("volume.automation.history"), systemImage: "clock.arrow.circlepath")
                } footer: {
                    Text(L("volume.automation.history.desc"))
                }
            }

            if let errorMessage = service.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Text(L("volume.presetSync.desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent(L("volume.presetSync.folder")) {
                    HStack(spacing: 8) {
                        Text(
                            presetSync.fileURL?.deletingLastPathComponent().lastPathComponent
                                ?? L("volume.presetSync.notSet")
                        )
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        Button(L("volume.presetSync.choose"), action: choosePresetSyncFolder)
                    }
                }

                HStack(spacing: 8) {
                    SecureField(L("volume.presetSync.passphrase"), text: $presetSyncPassphrase)
                    Button(L("volume.presetSync.save")) {
                        presetSync.storePassphrase(presetSyncPassphrase)
                        presetSyncPassphrase = ""
                    }
                    .disabled(presetSyncPassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if presetSync.hasStoredPassphrase {
                        Button(L("volume.presetSync.clear")) {
                            presetSync.clearPassphrase()
                        }
                    }
                }
                if presetSync.hasStoredPassphrase {
                    Label(L("volume.presetSync.passphraseSaved"), systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(L("volume.presetSync.auto"), isOn: Binding(
                    get: { presetSync.isEnabled },
                    set: { _ = presetSync.setEnabled($0) }
                ))
                .disabled(!presetSync.hasStoredPassphrase || presetSync.fileURL == nil)

                if presetSync.isEnabled {
                    Picker(L("volume.presetSync.interval"), selection: Binding(
                        get: { presetSync.intervalMinutes },
                        set: { presetSync.setIntervalMinutes($0) }
                    )) {
                        ForEach(AppVolumePresetSyncSettings.intervalOptions, id: \.self) { minutes in
                            Text(L("volume.presetSync.interval.minutes", minutes)).tag(minutes)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button(L("volume.presetSync.syncNow"), action: synchronizePresetsNow)
                        .disabled(
                            presetSync.isSyncing
                                || !presetSync.hasStoredPassphrase
                                || presetSync.fileURL == nil
                        )
                    if presetSync.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    Text(presetSyncLastSyncText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = presetSync.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !presetSyncConflictCopies.isEmpty {
                    HStack(spacing: 8) {
                        Label(
                            L("volume.presetSync.conflict", presetSyncConflictCopies.count),
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                        Button(L("volume.presetSync.reveal")) {
                            NSWorkspace.shared.activateFileViewerSelecting(presetSyncConflictCopies)
                        }
                    }
                }
            } header: {
                Label(L("volume.presetSync.title"), systemImage: "arrow.triangle.2.circlepath")
            }
            .onAppear(perform: refreshPresetSyncState)

            } else {
            Section {
                Toggle(L("volume.settings.showAdvanced"), isOn: $showsAdvancedSettings)
            } footer: {
                Text(L("volume.settings.showAdvancedHint"))
                    .font(.caption)
            }
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

                Picker(selection: Binding(
                    get: { service.menuBarDisplayMode },
                    set: { service.setMenuBarDisplayMode($0) }
                )) {
                    ForEach(AppVolumeMenuBarDisplayMode.allCases, id: \.self) { mode in
                        Text(L(mode.titleKey)).tag(mode)
                    }
                } label: {
                    Label(L("volume.menuBar.title"), systemImage: "menubar.rectangle")
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

                Text(L("volume.shortcut.mediaKeyHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(AppVolumeShortcutAction.allCases) { action in
                    volumeShortcutControl(for: action)
                }
            } header: {
                Label(L("volume.section.control"), systemImage: "waveform.badge.magnifyingglass")
            }

            Section {
                HStack {
                    Text(L("volume.masterLimit"))
                    Slider(value: Binding(
                        get: { service.masterVolumeLimit },
                        set: { service.setMasterVolumeLimit($0) }
                    ), in: 0.1...1)
                    Text("\(Int((service.masterVolumeLimit * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Toggle(L("volume.masterLimit.headphones"), isOn: Binding(
                    get: { service.limitsHeadphoneVolume },
                    set: { service.setLimitsHeadphoneVolume($0) }
                ))
                if let warning = service.hearingWarningMessage {
                    HStack {
                        Label(warning, systemImage: "ear.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(L("common.gotIt"), action: service.dismissHearingWarning)
                    }
                }
            } header: {
                Label(L("volume.hearing.title"), systemImage: "ear")
            }
            if showsAdvancedSettings {
            Section {
                Toggle(L("volume.meetingDucking"), isOn: Binding(
                    get: { service.meetingDuckingEnabled },
                    set: { service.setMeetingDuckingEnabled($0) }
                ))
                HStack {
                    Text(L("volume.meetingDucking.keepVolume"))
                    Slider(value: Binding(
                        get: { service.meetingDuckingFactor },
                        set: { service.setMeetingDuckingFactor($0) }
                    ), in: 0.1...0.8)
                    Text("\(Int((service.meetingDuckingFactor * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if service.isMeetingDuckingActive {
                    Label(L("volume.meetingDucking.active"), systemImage: "person.2.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            } header: {
                Label(L("volume.meetingDucking.title"), systemImage: "person.2.wave.2")
            }
            Section {
                if let remaining = service.sleepTimerRemainingMinutes {
                    LabeledContent(L("volume.sleepTimer.active", remaining)) {
                        Button(L("volume.sleepTimer.cancel")) {
                            service.cancelSleepTimer()
                        }
                    }
                } else {
                    Menu(L("volume.sleepTimer.start")) {
                        ForEach(AppVolumeSleepTimer.minuteOptions, id: \.self) { minutes in
                            Button(L("volume.sleepTimer.minutes", minutes)) {
                                service.startSleepTimer(minutes: minutes)
                            }
                        }
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                }

                Text(L("volume.sleepTimer.desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if service.sleepTimerDidFinish {
                    HStack(spacing: 8) {
                        Label(L("volume.sleepTimer.finished"), systemImage: "moon.zzz.fill")
                            .foregroundStyle(.secondary)
                        Button(L("volume.sleepTimer.dismiss")) {
                            service.acknowledgeSleepTimerFinish()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            } header: {
                Label(L("volume.sleepTimer.title"), systemImage: "moon.zzz")
            }
            }

            Section {
                LabeledContent(L("volume.notification.permission.title")) {
                    HStack(spacing: 8) {
                        Text(L(service.notificationPermission.titleKey))
                            .foregroundStyle(service.notificationPermission == .denied ? .orange : .secondary)
                        if service.notificationPermission != .authorized {
                            Button(L("volume.notification.openSettings"), action: openSystemSettings)
                        }
                    }
                }
                ForEach(AppVolumeNotificationKind.allCases, id: \.self) { kind in
                    Toggle(isOn: Binding(
                        get: { service.notificationPolicy.isEnabled(kind) },
                        set: { service.setNotificationEnabled($0, for: kind) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L(kind.titleKey))
                            Text(L(kind.detailKey))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Label(L("volume.notification.title"), systemImage: "bell.badge")
            }
            .onAppear {
                Task { await service.refreshNotificationPermission() }
            }

            if showsAdvancedSettings {
            Section {
                ForEach(service.selfCheckSteps) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: step.status.symbolName)
                            .foregroundStyle(selfCheckColor(for: step.status))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L(step.titleKey))
                            Text(step.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } header: {
                Label(L("volume.selfCheck.title"), systemImage: "checklist")
            }

            Section {
                Button(didCopyDiagnostic ? L("volume.diagnostics.copied") : L("volume.diagnostics.copy")) {
                    didCopyDiagnostic = service.copyDiagnosticReport()
                }
                Text(L("volume.diagnostics.desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label(L("volume.diagnostics.title"), systemImage: "stethoscope")
            }
            }
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
                presetTransferMessage = L("volume.preset.importSuccess")
            } catch {
                presetTransferMessage = L("volume.preset.importFailure", error.localizedDescription)
            }
        }
        .fileExporter(
            isPresented: $isExportingPresets,
            document: presetDocument,
            contentType: .json,
            defaultFilename: L("volume.preset.defaultName")
        ) { result in
            if case let .failure(error) = result {
                presetTransferMessage = L("volume.preset.exportFailure", error.localizedDescription)
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

    private func selfCheckColor(for status: AppVolumeSelfCheckStatus) -> Color {
        switch status {
        case .pass: .green
        case .warning: .orange
        case .failure: .red
        }
    }

    private func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 新建预设

    /// 新建预设入口：默认只显示「＋」，点它才展开表单，不再一进预设页就摆一个空白表单。
    @ViewBuilder
    private var presetCreationRow: some View {
        if presetDraft.isExpanded {
            HStack {
                TextField(L("volume.preset.name"), text: $presetDraft.name)
                Menu(L("volume.preset.includesApps", presetDraft.appIdentifiers.isEmpty ? service.sessions.count : presetDraft.appIdentifiers.count)) {
                    ForEach(service.sessions) { session in
                        Toggle(session.displayName, isOn: draftIncludesAppsBinding(session))
                    }
                }
                Button(L("volume.preset.save")) {
                    saveDraftedPreset()
                }
                .disabled(!presetDraft.canSave)
                Button(L("common.cancel")) {
                    presetDraft.finish()
                }
                .focusable(false)
                .focusEffectDisabled()
            }
        } else {
            Button {
                presetDraft.begin()
            } label: {
                Label(L("volume.preset.new"), systemImage: "plus")
            }
            .focusable(false)
            .focusEffectDisabled()
        }
    }

    /// 新预设的 App 勾选：空集代表「全部 App」，取消第一个勾选时先落成显式集合。
    private func draftIncludesAppsBinding(_ session: AppAudioSession) -> Binding<Bool> {
        Binding(
            get: { presetDraft.appIdentifiers.isEmpty || presetDraft.appIdentifiers.contains(session.id) },
            set: { enabled in
                if presetDraft.appIdentifiers.isEmpty {
                    presetDraft.appIdentifiers = Set(service.sessions.map(\.id))
                }
                if enabled { presetDraft.appIdentifiers.insert(session.id) }
                else { presetDraft.appIdentifiers.remove(session.id) }
            }
        )
    }

    /// 用草稿里的名称与 App 选择保存一个新预设，保存后收起表单。
    private func saveDraftedPreset() {
        let identifiers = presetDraft.appIdentifiers.isEmpty ? Set(service.sessions.map(\.id)) : presetDraft.appIdentifiers
        let levels = Dictionary(uniqueKeysWithValues: service.sessions.compactMap { session in
            identifiers.contains(session.id) ? (session.id, session.volume) : nil
        })
        _ = service.savePreset(named: presetDraft.name, appVolumes: levels)
        presetDraft.finish()
    }

    // MARK: - 预设跨设备同步

    private var presetSyncLastSyncText: String {
        guard let date = presetSync.lastSyncedAt else {
            return L("volume.presetSync.never")
        }
        return L("volume.presetSync.lastSync", date.formatted(date: .abbreviated, time: .shortened))
    }

    private func refreshPresetSyncState() {
        presetSyncConflictCopies = presetSync.conflictCopies
    }

    private func choosePresetSyncFolder() {
        let panel = NSOpenPanel()
        panel.title = L("volume.presetSync.choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let url = presetSync.fileURL {
            panel.directoryURL = url.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        presetSync.setFileURL(folder.appendingPathComponent(AppVolumePresetSyncSettings.fileName))
        presetSync.clearLastError()
        refreshPresetSyncState()
    }

    private func synchronizePresetsNow() {
        guard let passphrase = presetSync.storedPassphrase() else { return }
        _ = presetSync.synchronize(passphrase: passphrase)
        refreshPresetSyncState()
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
            Picker(L("volume.output.device"), selection: $rule.outputDeviceUID) {
                Text(L("volume.output.any")).tag(nil as String?)
                ForEach(outputDevices) { device in
                    Text(device.name).tag(device.uid as String?)
                }
            }
            Toggle(L("volume.automation.schedule"), isOn: $useTimeRange)
            if useTimeRange {
                TextField(L("volume.automation.startTime"), text: $startMinute)
                TextField(L("volume.automation.endTime"), text: $endMinute)
            }
            Picker(L("volume.automation.focus"), selection: $focusModeRequirement) {
                Text(L("volume.automation.focus.any")).tag(0)
                Text(L("volume.automation.focus.required")).tag(1)
                Text(L("volume.automation.focus.blocked")).tag(2)
            }
            TextField(L("volume.automation.bundleID"), text: Binding(
                get: { rule.launchBundleID ?? "" },
                set: { rule.launchBundleID = $0 }
            ))
            TextField(L("volume.automation.wifi"), text: Binding(
                get: { rule.wifiName ?? "" },
                set: { rule.wifiName = $0 }
            ))
        }
        .padding()
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("common.cancel"), action: dismiss.callAsFunction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L("common.save")) {
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
            .foregroundStyle(service.output.isMuted ? Color.orange : Color.secondary)
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
            .accessibilityLabel(L("volume.input.levelAccessibility"))
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
                    .help(L("volume.accessibility.group", L(session.appGroup.titleKey)))
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
                    set: { service.setVolume($0, for: session.rootBundleID, isUserAdjustment: true) }
                ), in: 0...service.maximumAppGain, onEditingChanged: { editing in
                    service.setVolumeAdjustmentActive(editing)
                })
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
                .accessibilityLabel(L("volume.accessibility.meter", session.displayName))

                Image(systemName: routeStatusSymbol)
                    .font(.caption2)
                    .foregroundStyle(routeStatusColor)
                    .help(L("volume.accessibility.route", Int((session.meter.cpuLoad * 100).rounded())))

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
                set: { service.setVolume($0, for: session.rootBundleID, isUserAdjustment: true) }
            ), in: 0...service.maximumAppGain, onEditingChanged: { editing in
                service.setVolumeAdjustmentActive(editing)
            })
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

/// 输出设备选择（独立成页，调音台只保留音量条）。
private struct AppVolumeOutputDeviceSection: View {
    @Bindable var service: AppVolumeService

    var body: some View {
        Section {
            if service.outputDevices.isEmpty {
                Text(L("volume.output.none"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.outputDevices) { device in
                    Button {
                        service.selectOutputDevice(device)
                    } label: {
                        HStack(spacing: 8) {
                            Label(
                                device.name,
                                systemImage: device.isDefault ? "checkmark.seal" : "speaker.wave.2"
                            )
                            Spacer()
                            if device.uid == service.output.deviceUID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                }
            }
        } header: {
            Label(L("volume.section.output"), systemImage: "speaker.wave.2")
        }
    }
}

/// 输入设备选择。
private struct AppVolumeInputDeviceSection: View {
    @Bindable var service: AppVolumeService

    var body: some View {
        Section {
            if service.inputDevices.isEmpty {
                Text(L("volume.input.none"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.inputDevices) { device in
                    Button {
                        service.selectInputDevice(device)
                    } label: {
                        HStack(spacing: 8) {
                            Label(device.name, systemImage: "mic")
                            Spacer()
                            if device.uid == service.input.deviceUID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusEffectDisabled()
                }
            }
        } header: {
            Label(L("volume.section.input"), systemImage: "mic")
        }
    }
}

/// 分组音量推子：一次调整该分组下的所有 App。
private struct AppVolumeGroupVolumeRow: View {
    @Bindable var service: AppVolumeService
    let group: AppVolumeAppGroup

    private var groupSessions: [AppAudioSession] {
        service.sessions(in: group)
    }

    private var displayedVolume: Double {
        service.groupVolume(group) ?? service.groupAverageVolume(group) ?? 1
    }

    private var isMixed: Bool {
        service.groupVolume(group) == nil && !groupSessions.isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if service.isGroupMuted(group) {
                    service.restoreGroup(group)
                } else {
                    service.muteGroup(group)
                }
            } label: {
                Image(systemName: service.isGroupMuted(group) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(service.isGroupMuted(group) ? Color.orange : Color.accentColor)
            .disabled(groupSessions.isEmpty)
            .accessibilityLabel(L("volume.groupVolume.title"))

            VStack(alignment: .leading, spacing: 1) {
                Text(L(group.titleKey))
                    .font(.caption)
                Text(
                    groupSessions.isEmpty
                        ? L("volume.groupVolume.empty")
                        : "\(groupSessions.count)"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .frame(width: 78, alignment: .leading)

            Slider(
                value: Binding(
                    get: { displayedVolume },
                    set: { service.setGroupVolume($0, for: group) }
                ),
                in: 0 ... service.maximumAppGain
            )
            .disabled(groupSessions.isEmpty)
            .accessibilityLabel(L(group.titleKey))

            Text(
                isMixed
                    ? L("volume.groupVolume.mixed")
                    : "\(Int((displayedVolume * 100).rounded()))%"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct AppVolumeEqualizerEditor: View {
    @Bindable var service: AppVolumeService
    let rootBundleID: String
    @State private var showsPresetPicker = false
    @State private var showsOutputPicker = false
    @State private var customEqualizerName = ""

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

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    controlLabel(L("volume.pan.title"), systemImage: "arrow.left.and.right")
                    HStack(spacing: 8) {
                        Text("L")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { session?.pan ?? 0 },
                                set: { service.setPan($0, for: rootBundleID) }
                            ),
                            in: AppVolumeChannelMix.minimumPan ... AppVolumeChannelMix.maximumPan
                        )
                        .controlSize(.small)
                        .frame(width: 150)
                        Text("R")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(Int(((session?.pan ?? 0) * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                        Button(L("volume.pan.reset")) {
                            service.setPan(0, for: rootBundleID)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .focusable(false)
                        .focusEffectDisabled()
                        .disabled(abs(session?.pan ?? 0) < 0.001)
                    }
                }

                Divider()

                Toggle(isOn: Binding(
                    get: { session?.isMono ?? false },
                    set: { service.setMono($0, for: rootBundleID) }
                )) {
                    Text(L("volume.mono.title"))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .focusable(false)
                .focusEffectDisabled()
            }
            .font(.caption)
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Toggle(isOn: Binding(
                get: { session?.skipRouting ?? false },
                set: { service.setSkipRouting($0, for: rootBundleID) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("volume.skipRouting.title"))
                    Text(L("volume.skipRouting.desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .focusable(false)
            .focusEffectDisabled()

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

                Divider()
                    .padding(.vertical, 4)

                Text(L("volume.equalizer.custom.library"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)

                if service.customEqualizers.isEmpty {
                    Text(L("volume.equalizer.custom.empty"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                } else {
                    ForEach(service.customEqualizers) { custom in
                        Button {
                            service.applyCustomEqualizer(id: custom.id, to: rootBundleID)
                            showsPresetPicker = false
                        } label: {
                            HStack {
                                Text(custom.name)
                                    .lineLimit(1)
                                Spacer()
                                if equalizer.gains == custom.gains {
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
                        .contextMenu {
                            Button(L("volume.equalizer.custom.delete"), role: .destructive) {
                                service.deleteCustomEqualizer(id: custom.id)
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 190, height: 250)
        .safeAreaInset(edge: .bottom) {
            customEqualizerSaver
        }
    }

    /// 把当前曲线存进「我的 EQ 预设」。
    private var customEqualizerSaver: some View {
        HStack(spacing: 6) {
            TextField(L("volume.equalizer.custom.name"), text: $customEqualizerName)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.caption)
                .onSubmit(saveCustomEqualizer)
            Button(action: saveCustomEqualizer) {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focusable(false)
            .focusEffectDisabled()
            .disabled(customEqualizerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(L("volume.equalizer.custom.save"))
        }
        .padding(8)
        .background(.regularMaterial)
    }

    private func saveCustomEqualizer() {
        let name = customEqualizerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        service.saveCustomEqualizer(named: name, gains: equalizer.gains)
        customEqualizerName = ""
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
