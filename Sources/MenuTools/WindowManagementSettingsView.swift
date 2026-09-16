import AppKit
import SwiftUI

/// 窗口管理设置页的子页。
///
/// 一个页面塞不下（布局列表单独就有 60 项、约 4 屏），按用户任务拆成四页，
/// 与网络流量设置页用同一套「分段控件 + switch」模式。
private enum WindowManagementSection: String, CaseIterable {
    case layouts
    case snapping
    case presets
    case rules

    var titleKey: String { "window.tab.\(rawValue)" }
    var symbol: String {
        switch self {
        case .layouts: return "rectangle.split.2x2"
        case .snapping: return "arrow.up.left.and.arrow.down.right"
        case .presets: return "bookmark"
        case .rules: return "app.badge.checkmark"
        }
    }
}

/// 窗口布局与快捷键设置。
struct WindowManagementSettingsView: View {
    @Bindable private var shortcutService: WindowShortcutService
    @Bindable private var windowService: WindowManagementService
    @State private var recordingLayout: WindowLayout?
    @State private var isRecordingQuickAccessShortcut = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var newPresetName = ""
    @State private var presetLayout: WindowLayout = .leftHalf
    @State private var ruleLayout: WindowLayout = .leftHalf
    @State private var ruleTitleFilter = ""
    @State private var ruleFirstWindowOnly = false
    @State private var layoutQuery = ""
    @State private var recordingPresetID: UUID?
    @State private var section: WindowManagementSection = .layouts
    @State private var expandedGroups: Set<WindowLayoutGroup> = WindowLayoutGrouping.defaultExpandedGroups
    @State private var snapAreasExpanded = false

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

                feedbackLine

                sectionPicker

                // 必须放在滚动内容顶部，确保窗口打开时就已创建并可成为第一响应者，
                // 同时不随子页切换销毁——否则切页会中断正在进行的快捷键录制。
                WindowShortcutCaptureView(isRecording: recordingLayout != nil || isRecordingQuickAccessShortcut || recordingPresetID != nil) { shortcut in
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
                    if let presetID = recordingPresetID {
                        recordingPresetID = nil
                        guard let shortcut,
                              let preset = windowService.configuration.presets.first(where: { $0.id == presetID }) else { return }
                        do {
                            try shortcutService.setPresetBinding(shortcut, for: preset)
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

                // 切换子页时重建内容容器，保证新页从顶部开始；可变状态都声明在本视图上。
                GlassEffectContainer(spacing: 4) {
                    sectionContent
                }
                .id(section)

            }
            .padding(16)
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .navigationTitle(L("settings.title"))
        .onAppear {
            // 清理上一版删除预设后残留的快捷键绑定。
            shortcutService.prunePresetBindings(keeping: Set(windowService.configuration.presets.map(\.id)))
        }
    }

    private var sectionPicker: some View {
        Picker(L("window.tabs"), selection: $section) {
            ForEach(WindowManagementSection.allCases, id: \.self) { item in
                Label(L(item.titleKey), systemImage: item.symbol).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(L("window.tabs"))
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .layouts:
            layoutsPage
        case .snapping:
            snappingPage
        case .presets:
            presetsPage
        case .rules:
            rulesPage
        }
    }

    private var layoutsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            quickAccessShortcutSection
            layoutSection
            windowActionsCard
        }
    }

    private var snappingPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            managerOptionsSection
            snapAreaSection
        }
    }

    private var presetsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            presetSection
        }
    }

    private var rulesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            applicationRulesSection
            exclusionSection
        }
    }

    private var quickAccessShortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("keyboard", L("window.quickAccess.shortcut"))
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
        .modifier(WindowSettingsCard())
    }

    private var managerOptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("slider.horizontal.3", L("window.manager.section"))

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
            optionSlider(
                title: L("window.manager.nudgeStep"),
                value: optionBinding(\WindowManagerOptions.nudgeStep),
                range: 4...80
            )

            Toggle(L("window.manager.edgeSnapping"), isOn: Binding(
                get: { windowService.configuration.edgeSnappingEnabled },
                set: { windowService.setEdgeSnappingEnabled($0) }
            ))
            Toggle(L("window.manager.snapPreview"), isOn: Binding(
                get: { windowService.configuration.showSnapPreview },
                set: { windowService.setSnapPreviewEnabled($0) }
            ))
            .disabled(!windowService.configuration.edgeSnappingEnabled)
            Toggle(L("window.manager.haptic"), isOn: Binding(
                get: { windowService.configuration.hapticFeedbackOnSnap },
                set: { windowService.setHapticFeedbackEnabled($0) }
            ))
            .disabled(!windowService.configuration.edgeSnappingEnabled)
            Toggle(L("window.manager.detailedSnapAreas"), isOn: Binding(
                get: { windowService.configuration.detailedSnapAreas },
                set: { windowService.setDetailedSnapAreasEnabled($0) }
            ))
            .disabled(!windowService.configuration.edgeSnappingEnabled)
            Toggle(L("window.manager.cycleLayouts"), isOn: Binding(
                get: { windowService.configuration.cycleLayouts },
                set: { windowService.setCycleLayoutsEnabled($0) }
            ))
            Toggle(L("window.manager.traverseDisplays"), isOn: Binding(
                get: { windowService.configuration.traverseDisplaysOnRepeat },
                set: { windowService.setTraverseDisplaysEnabled($0) }
            ))
            .disabled(NSScreen.screens.count < 2)
            Toggle(L("window.manager.restoreSizeOnDragOut"), isOn: Binding(
                get: { windowService.configuration.restoreSizeWhenDraggingOut },
                set: { windowService.setRestoreSizeOnDragOutEnabled($0) }
            ))
            Toggle(L("window.manager.autoRules"), isOn: Binding(
                get: { windowService.configuration.automaticApplicationRules },
                set: { windowService.setAutomaticApplicationRulesEnabled($0) }
            ))
        }
        .modifier(WindowSettingsCard())
    }

    /// 吸附区域动作自定义（Rectangle Pro 那类）：每个区域触发哪个布局。
    private var snapAreaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("rectangle.split.3x3", L("window.manager.snapAreas"))
                Spacer()
                Button(L("window.manager.snapAreaReset")) {
                    windowService.resetSnapAreaMapping()
                }
                .font(.caption)
                .disabled(windowService.configuration.snapAreaMapping.isEmpty)
            }
            Text(L("window.manager.snapAreasHint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup(isExpanded: $snapAreasExpanded) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 6
                ) {
                    ForEach(WindowSnapArea.customizable, id: \.self) { area in
                    HStack(spacing: 6) {
                        Text(L(area.titleKey))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Picker("", selection: snapAreaBinding(area)) {
                            Text(L("window.manager.snapAreaDefault"))
                                .tag(WindowLayout?.none)
                            ForEach(WindowLayout.allCases) { layout in
                                Text(L(layout.titleKey)).tag(WindowLayout?.some(layout))
                            }
                        }
                            .labelsHidden()
                            .font(.caption)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(L("window.manager.snapAreasAdvanced"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .modifier(WindowSettingsCard())
    }

    private func snapAreaBinding(_ area: WindowSnapArea) -> Binding<WindowLayout?> {
        Binding(
            get: { windowService.configuration.snapAreaMapping.override(for: area) },
            set: { windowService.setSnapAreaAction($0, for: area) }
        )
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("bookmark", L("window.manager.presets"))
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
                    if preset.hasCustomFrame {
                        Text(L("window.manager.presetFrame"))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                    Spacer()
                    Text(recordingPresetID == preset.id
                         ? L("shortcut.recording")
                         : (shortcutService.presetBinding(for: preset.id)?.displayName ?? L("settings.unset")))
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .foregroundStyle(recordingPresetID == preset.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Button {
                        recordingLayout = nil
                        isRecordingQuickAccessShortcut = false
                        errorMessage = nil
                        recordingPresetID = recordingPresetID == preset.id ? nil : preset.id
                    } label: {
                        Image(systemName: recordingPresetID == preset.id ? "xmark" : "record.circle")
                    }
                    .buttonStyle(.plain)
                    .help(L("shortcut.record"))
                    if shortcutService.presetBinding(for: preset.id) != nil {
                        Button {
                            shortcutService.clearPresetBinding(for: preset.id)
                        } label: {
                            Image(systemName: "delete.left")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(L("shortcut.clear"))
                    }
                    Button(L("window.apply")) { apply(preset) }
                    Button {
                        recordingPresetID = recordingPresetID == preset.id ? nil : recordingPresetID
                        shortcutService.clearPresetBinding(for: preset.id)
                        windowService.removePreset(preset)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Button {
                capturePreset()
            } label: {
                Label(L("window.manager.capturePreset"), systemImage: "ruler")
                    .font(.caption)
            }
            .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .modifier(WindowSettingsCard())
    }

    private var applicationRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("app.badge.checkmark", L("window.manager.applicationRules"))
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
                    TextField(L("window.manager.ruleTitleFilter"), text: $ruleTitleFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    Toggle(L("window.manager.ruleFirstWindowOnly"), isOn: $ruleFirstWindowOnly)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Button(L("window.manager.bind")) {
                        windowService.addOrUpdateApplicationRule(
                            for: application,
                            layout: ruleLayout,
                            windowTitleContains: ruleTitleFilter,
                            firstWindowOnly: ruleFirstWindowOnly
                        )
                        ruleTitleFilter = ""
                        ruleFirstWindowOnly = false
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
                        Text(ruleSummary(rule))
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
        .modifier(WindowSettingsCard())
    }

    private var exclusionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("nosign", L("window.manager.exclusions"))
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
        .modifier(WindowSettingsCard())
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

    /// 规则列表里的摘要：布局名 + 可选的标题过滤与主窗口限定。
    private func ruleSummary(_ rule: WindowApplicationRule) -> String {
        var parts = [L(rule.layout.titleKey)]
        if let filter = rule.windowTitleContains {
            parts.append(L("window.manager.ruleTitle", filter))
        }
        if rule.firstWindowOnly {
            parts.append(L("window.manager.ruleFirstWindowOnly"))
        }
        return parts.joined(separator: " · ")
    }

    private func apply(_ preset: WindowLayoutPreset) {
        do {
            try windowService.apply(preset)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 把当前窗口的位置与尺寸保存成固定尺寸预设，避免预设只能引用布局。
    private func capturePreset() {
        do {
            let preset = try windowService.capturePreset(name: newPresetName)
            statusMessage = L("window.manager.capturedPreset", preset.name)
            errorMessage = nil
            newPresetName = ""
        } catch {
            statusMessage = nil
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
        HStack(spacing: 6) {
            Button {
                apply(layout)
            } label: {
                HStack(spacing: 7) {
                    WindowLayoutIcon(layout: layout)
                        .frame(width: 18, height: 14)
                    Text(L(layout.titleKey))
                        .font(.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 2)
                    shortcutBadge(for: layout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .controlCenterHover(shape: AnyShape(.rect(cornerRadius: 8)))
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
    }

    /// 快捷键用胶囊标签呈现：未设置时很轻，绑定后是等宽字体，录制中高亮。
    private func shortcutBadge(for layout: WindowLayout) -> some View {
        let binding = shortcutService.binding(for: layout)
        let isRecording = recordingLayout == layout
        let text = isRecording
            ? L("shortcut.recording")
            : (binding?.displayName ?? L("settings.unset"))
        let fill: AnyShapeStyle = isRecording
            ? AnyShapeStyle(Color.accentColor.opacity(0.16))
            : AnyShapeStyle(.quaternary.opacity(binding == nil ? 0.35 : 0.75))

        return Text(text)
            .font(.caption2.monospaced())
            .lineLimit(1)
            .foregroundStyle(isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(binding == nil ? .tertiary : .secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(fill, in: .capsule)
    }

    /// 卡片标题：图标 + 标题（+ 可选副标题），全局统一。
    private func sectionHeader(_ symbol: String, _ title: String, subtitle: String? = nil) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 15)
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// 顶部反馈行：错误与状态就近显示，不再沉在长页面底部。
    @ViewBuilder
    private var feedbackLine: some View {
        if let errorMessage {
            feedbackText(errorMessage, symbol: "exclamationmark.triangle.fill", tint: .red)
        } else if let statusMessage {
            feedbackText(statusMessage, symbol: "checkmark.circle.fill", tint: .green)
        } else if let lastError = shortcutService.lastError {
            feedbackText(lastError, symbol: "exclamationmark.triangle.fill", tint: .red)
        }
    }

    private func feedbackText(_ message: String, symbol: String, tint: Color) -> some View {
        Label(message, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(tint)
            .lineLimit(2)
    }

    private var matchedSections: [(group: WindowLayoutGroup, layouts: [WindowLayout])] {
        WindowLayoutGrouping.sections(query: layoutQuery) { L($0.titleKey) }
    }

    private var matchedLayoutCount: Int {
        matchedSections.reduce(0) { $0 + $1.layouts.count }
    }

    /// 布局与快捷键：搜索 + 按形状族分组，替代原来 60 项平铺的一整面墙。
    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.split.2x2")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 15)
                Text(L("window.manager.layouts"))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Button(allGroupsExpanded ? L("window.manager.collapseAll") : L("window.manager.expandAll")) {
                    expandedGroups = allGroupsExpanded ? [] : Set(WindowLayoutGroup.allCases)
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                Text(L("window.manager.layoutCount", matchedLayoutCount, WindowLayout.allCases.count))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            layoutSearchField

            if matchedLayoutCount == 0 {
                Text(L("window.manager.layoutSearchEmpty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(matchedSections, id: \.group) { filtered in
                    DisclosureGroup(isExpanded: expansionBinding(filtered.group)) {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)
                            ],
                            spacing: 6
                        ) {
                            ForEach(filtered.layouts) { layoutRow($0) }
                        }
                        .padding(.top, 6)
                    } label: {
                        groupHeader(filtered.group, count: filtered.layouts.count)
                    }
                }
            }
        }
        .modifier(WindowSettingsCard())
    }

    private var allGroupsExpanded: Bool {
        expandedGroups.count == WindowLayoutGroup.allCases.count
    }

    /// 分组折叠状态：搜索激活时一律展开（否则会出现搜到了却看不见）。
    /// 搜索期间不写回手动集合，清空搜索后恢复用户原来的折叠状态。
    private func expansionBinding(_ group: WindowLayoutGroup) -> Binding<Bool> {
        Binding(
            get: {
                WindowLayoutGrouping.shouldExpand(
                    group,
                    query: layoutQuery,
                    manuallyExpanded: expandedGroups
                )
            },
            set: { isExpanded in
                guard layoutQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                if isExpanded {
                    expandedGroups.insert(group)
                } else {
                    expandedGroups.remove(group)
                }
            }
        )
    }

    private var layoutSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(L("window.manager.layoutSearch"), text: $layoutQuery)
                .textFieldStyle(.plain)
                .font(.caption)
            if !layoutQuery.isEmpty {
                Button {
                    layoutQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
    }

    private func groupHeader(_ group: WindowLayoutGroup, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(L(group.titleKey))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    /// 窗口级操作单独成卡，不再游离在布局网格下面。
    private var windowActionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("wand.and.rays", L("window.manager.actions"))
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
        }
        .modifier(WindowSettingsCard())
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

/// 设置页卡片的统一表面：圆角、内边距与玻璃效果只在这里定义。
private struct WindowSettingsCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}
