import AppKit
import SwiftUI

enum ClipboardHistorySettingsLayout {
    static let contentHorizontalPadding: CGFloat = 24
    static let historyGridSpacing: CGFloat = 12

    static func columnCount(for availableWidth: CGFloat) -> Int {
        availableWidth >= 500 ? 2 : 1
    }
}

enum ClipboardHistorySettingsTab: String, CaseIterable, Identifiable, Sendable {
    case history
    case snippets
    case settings

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .history: "clipboard.history"
        case .snippets: "clipboard.snippets"
        case .settings: "clipboard.tab.settings"
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .snippets: "text.quote"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum ClipboardShortcutControlPolicy {
    static func shouldShowSave(hasCapturedShortcut: Bool) -> Bool {
        hasCapturedShortcut
    }

    static func shouldShowClear(hasBinding: Bool, isRecording: Bool) -> Bool {
        hasBinding && !isRecording
    }
}

enum ClipboardHistoryPreviewLayout {
    static let thumbnailSize = CGSize(width: 64, height: 64)
    static let hoverPreviewSize = CGSize(width: 272, height: 188)
}

/// 悬停预览根据卡片锚点就近显示，避免固定在页面角落。
enum ClipboardHistoryPreviewPlacement {
    static let gap: CGFloat = 12
    static let edgePadding: CGFloat = 12

    static func position(for cardFrame: CGRect, in containerSize: CGSize) -> CGPoint {
        let previewSize = ClipboardHistoryPreviewLayout.hoverPreviewSize
        let minimumX = min(previewSize.width / 2 + edgePadding, containerSize.width / 2)
        let maximumX = max(minimumX, containerSize.width - previewSize.width / 2 - edgePadding)
        let minimumY = min(previewSize.height / 2 + edgePadding, containerSize.height / 2)
        let maximumY = max(minimumY, containerSize.height - previewSize.height / 2 - edgePadding)
        let prefersRightSide = cardFrame.midX <= containerSize.width / 2
        let preferredX = prefersRightSide
            ? cardFrame.maxX + gap + previewSize.width / 2
            : cardFrame.minX - gap - previewSize.width / 2

        return CGPoint(
            x: min(max(preferredX, minimumX), maximumX),
            y: min(max(cardFrame.midY, minimumY), maximumY)
        )
    }
}

private struct ClipboardHistoryHoverPreviewTarget {
    let item: ClipboardHistoryItem
    let anchor: Anchor<CGRect>
}

private struct ClipboardHistoryHoverPreviewPreferenceKey: PreferenceKey {
    static let defaultValue: ClipboardHistoryHoverPreviewTarget? = nil

    static func reduce(
        value: inout ClipboardHistoryHoverPreviewTarget?,
        nextValue: () -> ClipboardHistoryHoverPreviewTarget?
    ) {
        if let nextValue = nextValue() {
            value = nextValue
        }
    }
}

/// 剪贴板功能设置页：管理历史记录，并配置随时呼出的全局快捷键。
struct ClipboardHistorySettingsView: View {
    @State private var historyService = ClipboardHistoryService.shared
    @State private var shortcutService = ClipboardShortcutService.shared
    @State private var isRecording = false
    @State private var capturedShortcut: GlobalShortcut?
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var category: ClipboardHistoryCategory = .all
    @State private var sortOrder: ClipboardHistorySortOrder = .newestFirst
    @State private var sourceBundleID: String?
    @State private var dateFilter: ClipboardHistoryDateFilter = .all
    @State private var isHistoryScrolling = false
    @State private var selectedItemIDs = Set<UUID>()
    @State private var isSelectingItems = false
    @State private var selectedTab: ClipboardHistorySettingsTab = .history
    @State private var historyPageSize = 50

    private var displayedShortcut: GlobalShortcut? {
        capturedShortcut ?? shortcutService.binding
    }

    var body: some View {
        VStack(spacing: 0) {
            historyHeader
            workspacePicker
            Divider()

            ScrollView {
                workspaceContent
                .padding(ClipboardHistorySettingsLayout.contentHorizontalPadding)
            }
            .onScrollPhaseChange { _, phase in
                isHistoryScrolling = phase.isScrolling
            }
            .overlayPreferenceValue(ClipboardHistoryHoverPreviewPreferenceKey.self) { target in
                GeometryReader { proxy in
                    if let target, !isHistoryScrolling {
                        ClipboardHistoryHoverPreview(item: target.item)
                            .position(
                                ClipboardHistoryPreviewPlacement.position(
                                    for: proxy[target.anchor],
                                    in: proxy.size
                                )
                            )
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .task {
            await historyService.loadPersistedHistory()
            historyService.refresh()
        }
        .onChange(of: selectedTab) { _, tab in
            guard tab != .settings, isRecording else { return }
            isRecording = false
            capturedShortcut = nil
            errorMessage = nil
        }
        .onChange(of: searchText) { _, _ in historyPageSize = 50 }
        .onChange(of: category) { _, _ in historyPageSize = 50 }
        .onChange(of: sourceBundleID) { _, _ in historyPageSize = 50 }
        .onChange(of: dateFilter) { _, _ in historyPageSize = 50 }
    }

    private var workspacePicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(ClipboardHistorySettingsTab.allCases) { tab in
                Label(L(tab.titleKey), systemImage: tab.symbol)
                    .tag(tab)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .padding(.horizontal, ClipboardHistorySettingsLayout.contentHorizontalPadding)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch selectedTab {
        case .history:
            historyWorkspace
        case .snippets:
            ClipboardSnippetSettingsSection(historyService: historyService)
        case .settings:
            settingsWorkspace
        }
    }

    private var historyWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchField
            historyControls
            historyContent
        }
    }

    private var settingsWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            ClipboardHistoryManagementSettingsSection(historyService: historyService)
            ClipboardPrivacySettingsSection(historyService: historyService)
            shortcutSection
        }
    }

    private var historyHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(L("clipboard.history"))
                    .font(.title3.weight(.semibold))
                Text(L("clipboard.historyItems", historyService.items.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            Spacer()

            Menu {
                Button(L("clipboard.clearHistory"), role: .destructive) {
                    historyService.clearHistory()
                }
                .disabled(historyService.items.isEmpty)

                Button(L("clipboard.clearUnpinned"), role: .destructive) {
                    historyService.clearUnpinnedHistory()
                }
                .disabled(!historyService.items.contains(where: { !$0.isPinned }))

                Button(L("clipboard.clearLastHour"), role: .destructive) {
                    historyService.removeRecent(since: Date().addingTimeInterval(-3_600))
                }

                Button(L("clipboard.clearToday"), role: .destructive) {
                    historyService.removeRecent(since: Calendar.current.startOfDay(for: Date()))
                }

                Button(L("cleanup.clipboard"), role: .destructive, action: clearClipboard)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(L("clipboard.actions"))
        }
        .padding(.horizontal, ClipboardHistorySettingsLayout.contentHorizontalPadding)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L("clipboard.search"), text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 11))
    }

    private var historyControls: some View {
        HStack(spacing: 10) {
            Menu {
                Picker(L("clipboard.category"), selection: $category) {
                    ForEach(ClipboardHistoryCategory.allCases) { category in
                        Text(L(category.titleKey)).tag(category)
                    }
                }
                Picker(L("clipboard.sort"), selection: $sortOrder) {
                    ForEach(ClipboardHistorySortOrder.allCases) { sortOrder in
                        Text(L(sortOrder.titleKey)).tag(sortOrder)
                    }
                }

                Button(L("clipboard.source.all")) { sourceBundleID = nil }
                ForEach(sourceBundleIDs, id: \.self) { bundleID in
                    Button(sourceApplicationName(for: bundleID)) { sourceBundleID = bundleID }
                }

                ForEach(ClipboardHistoryDateFilter.allCases) { filter in
                    Button(L(filter.titleKey)) { dateFilter = filter }
                }

                Picker(L("clipboard.limit"), selection: Binding<ClipboardHistoryLimit>(
                    get: { ClipboardHistoryLimit(rawValue: historyService.limit) ?? .fifty },
                    set: { limit in historyService.setLimit(limit) }
                )) {
                    ForEach(ClipboardHistoryLimit.allCases) { limit in
                        Text(L("clipboard.limitValue", limit.rawValue)).tag(limit)
                    }
                }
            } label: {
                Label(filterMenuTitle, systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.bordered)
            .accessibilityLabel(L("clipboard.filters"))

            Spacer()

            Button(isSelectingItems ? L("clipboard.doneSelecting") : L("clipboard.select")) {
                isSelectingItems.toggle()
                if !isSelectingItems { selectedItemIDs.removeAll() }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if historyService.canUndoLastRemoval {
            HStack {
                Text(L("clipboard.removed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L("clipboard.undo")) { _ = historyService.undoLastRemoval() }
                    .controlSize(.small)
            }
        }

        if let progress = historyService.sequentialPasteProgress {
            HStack(spacing: 8) {
                Label(
                    L("clipboard.sequential.ready", progress.current, progress.total),
                    systemImage: "list.number"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button(L("clipboard.sequential.cancel")) {
                    historyService.cancelSequentialPaste()
                }
                .controlSize(.small)
            }
        }

        if filteredItems.isEmpty {
            ContentUnavailableView(
                historyService.items.isEmpty ? L("clipboard.empty") : L("clipboard.noResults"),
                systemImage: historyService.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                description: Text(historyService.items.isEmpty ? L("clipboard.emptyDescription") : L("clipboard.noResultsDescription"))
            )
            .frame(maxWidth: .infinity, minHeight: 210)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if isSelectingItems {
                    HStack {
                        Text(L("clipboard.selectedCount", selectedItemIDs.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Picker(L("clipboard.sequential.mode"), selection: Binding(
                                get: { historyService.sequentialPasteMode },
                                set: { mode in historyService.setSequentialPasteMode(mode) }
                            )) {
                                ForEach(ClipboardSequentialPasteMode.allCases) { mode in
                                    Text(L(mode.localizationKey)).tag(mode)
                                }
                            }
                        } label: {
                            Label(L(historyService.sequentialPasteMode.localizationKey), systemImage: "repeat")
                        }
                        .disabled(selectedItemIDs.isEmpty)
                        Button(L("clipboard.sequential.start")) {
                            historyService.beginSequentialPaste(itemIDs: filteredItems
                                .filter { selectedItemIDs.contains($0.id) }
                                .map(\.id))
                            isSelectingItems = false
                            selectedItemIDs.removeAll()
                        }
                        .disabled(selectedItemIDs.isEmpty)
                        Menu {
                            Button(L("clipboard.pinSelected")) {
                                historyService.setPinned(true, for: selectedItemIDs)
                            }
                            Button(L("clipboard.unpinSelected")) {
                                historyService.setPinned(false, for: selectedItemIDs)
                            }
                            Divider()
                            Button(L("clipboard.markSelectedSensitive")) {
                                historyService.setSensitive(true, for: selectedItemIDs)
                            }
                            Button(L("clipboard.unmarkSelectedSensitive")) {
                                historyService.setSensitive(false, for: selectedItemIDs)
                            }
                        } label: {
                            Label(L("clipboard.batchActions"), systemImage: "slider.horizontal.3")
                        }
                        .disabled(selectedItemIDs.isEmpty)
                        Button(L("clipboard.deleteSelected"), role: .destructive) {
                            historyService.remove(ids: selectedItemIDs)
                            selectedItemIDs.removeAll()
                        }
                        .disabled(selectedItemIDs.isEmpty)
                    }
                }

                ForEach(ClipboardHistoryDateSections.sections(from: filteredItems)) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sectionTitle(section.kind))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: ClipboardHistorySettingsLayout.historyGridSpacing),
                                count: ClipboardHistorySettingsLayout.columnCount(
                                    for: SettingsLayout.width - ClipboardHistorySettingsLayout.contentHorizontalPadding * 2
                                )
                            ),
                            spacing: ClipboardHistorySettingsLayout.historyGridSpacing
                        ) {
                            ForEach(section.items) { item in
                                ClipboardHistorySettingsCard(
                                    item: item,
                                    onCopy: { historyService.copy(item) },
                                    onTogglePinned: { historyService.togglePinned(id: item.id) },
                                    onToggleSensitive: { historyService.setSensitive(!item.isSensitive, for: item.id) },
                                    onSetTitle: { historyService.setTitle($0, for: item.id) },
                                    onSetTags: { historyService.setTags($0, for: item.id) },
                                    onSetNote: { historyService.setNote($0, for: item.id) },
                                    onTransform: { _ = historyService.copyTransformed(item, transform: $0) },
                                    onTranslate: {
                                        if let text = item.content.plainTextRepresentation {
                                            TranslationWindowController.shared.show(text: text)
                                        }
                                    },
                                    onRemove: { historyService.remove(id: item.id) },
                                    isHistoryScrolling: isHistoryScrolling,
                                    isSelecting: isSelectingItems,
                                    isSelected: selectedItemIDs.contains(item.id),
                                    onSelectionChanged: { isSelected in
                                        if isSelected {
                                            selectedItemIDs.insert(item.id)
                                        } else {
                                            selectedItemIDs.remove(item.id)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
                if filteredItems.count < allFilteredItems.count {
                    Button(L("clipboard.loadMore")) {
                        historyPageSize += 50
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var shortcutSection: some View {
        HStack(spacing: 16) {
            Text(L("clipboard.shortcut"))

            Spacer(minLength: 24)

            HStack(spacing: 10) {
                Text(isRecording ? L("settings.recording") : displayedShortcut?.displayName ?? L("settings.unset"))
                    .font(.callout.monospaced())
                    .foregroundStyle(isRecording || displayedShortcut != nil ? .primary : .secondary)

                if ClipboardShortcutControlPolicy.shouldShowSave(
                    hasCapturedShortcut: capturedShortcut != nil
                ) {
                    Button(L("clipboard.shortcutSave"), action: saveShortcut)
                }

                Button {
                    capturedShortcut = nil
                    errorMessage = nil
                    isRecording.toggle()
                } label: {
                    Image(systemName: isRecording ? "xmark" : "record.circle")
                }
                .help(isRecording ? L("settings.recording") : L("shortcut.record"))

                if ClipboardShortcutControlPolicy.shouldShowClear(
                    hasBinding: shortcutService.binding != nil,
                    isRecording: isRecording
                ) {
                    Button {
                        shortcutService.clearBinding()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(L("shortcut.clear"))
                }
            }
            Label(L(shortcutService.registrationMode.localizationKey), systemImage: shortcutService.registrationMode == .carbonExclusive ? "checkmark.shield" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(shortcutService.registrationMode == .carbonExclusive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .help(L("clipboard.shortcut.status.help"))
        }
        .help(L("clipboard.shortcutDescription"))
        .overlay(alignment: .bottomLeading) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .offset(y: 16)
            }
        }
        .padding(.vertical, 14)
        .padding(.bottom, errorMessage == nil ? 0 : 14)
        .overlay {
            GlobalShortcutCaptureView(isRecording: isRecording) { shortcut in
                isRecording = false
                guard let shortcut else { return }
                capturedShortcut = shortcut
                errorMessage = nil
            }
            .frame(width: 1, height: 1)
        }
    }

    private func saveShortcut() {
        guard let capturedShortcut else { return }
        do {
            try shortcutService.setBinding(capturedShortcut)
            self.capturedShortcut = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var filteredItems: [ClipboardHistoryItem] {
        Array(ClipboardHistoryList.page(allFilteredItems, offset: 0, pageSize: historyPageSize))
    }

    private var allFilteredItems: [ClipboardHistoryItem] {
        ClipboardHistoryList.items(
            from: historyService.items,
            query: searchText,
            category: category,
            sortOrder: sortOrder,
            sourceBundleID: sourceBundleID,
            dateFilter: dateFilter
        )
    }

    private var sourceBundleIDs: [String] {
        Array(Set(historyService.items.compactMap(\.sourceBundleID))).sorted()
    }

    private var filterMenuTitle: String {
        let count = [
            category != .all,
            sortOrder != .newestFirst,
            sourceBundleID != nil,
            dateFilter != .all,
            historyService.limit != ClipboardHistoryLimit.fifty.rawValue
        ].filter { $0 }.count
        return count == 0 ? L("clipboard.filters") : L("clipboard.filtersCount", count)
    }

    private func sourceApplicationName(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension().lastPathComponent ?? bundleID
    }

    private func clearClipboard() {
        historyService.clearSystemClipboard()
    }

    private func sectionTitle(_ kind: ClipboardHistoryDateSectionKind) -> String {
        switch kind {
        case .pinned: return L("clipboard.section.pinned")
        case .today: return L("clipboard.section.today")
        case .yesterday: return L("clipboard.section.yesterday")
        case let .date(date): return date.formatted(.dateTime.year().month().day())
        }
    }

}

private struct ClipboardHistorySettingsCard: View {
    let item: ClipboardHistoryItem
    let onCopy: () -> Bool
    let onTogglePinned: () -> Void
    let onToggleSensitive: () -> Void
    let onSetTitle: (String?) -> Void
    let onSetTags: ([String]) -> Void
    let onSetNote: (String?) -> Void
    let onTransform: (ClipboardTextTransform) -> Void
    let onTranslate: () -> Void
    let onRemove: () -> Void
    let isHistoryScrolling: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onSelectionChanged: (Bool) -> Void

    @State private var isHovered = false
    @State private var didCopy = false
    @State private var isEditingMetadata = false
    @State private var draftTitle = ""
    @State private var draftTags = ""
    @State private var draftNote = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isSelecting {
                Button { onSelectionChanged(!isSelected) } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? L("clipboard.deselect") : L("clipboard.select"))
            }
            Button(action: copyItem) {
                HStack(alignment: .top, spacing: 10) {
                    ClipboardHistoryThumbnail(id: item.id, content: item.content, isSensitive: item.isSensitive)

                    VStack(alignment: .leading, spacing: 6) {
                        if let title = item.title {
                            Text(title)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(previewText)
                            .font(item.title == nil ? .callout : .caption)
                            .foregroundStyle(item.title == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(item.title == nil ? 3 : 2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 5) {
                            Image(systemName: item.isPinned ? "pin.fill" : "clock")
                            Text(item.capturedAt, format: .dateTime.hour().minute())
                            if let sourceBundleID = item.sourceBundleID {
                                Text("·")
                                Text(sourceApplicationName(for: sourceBundleID))
                                    .lineLimit(1)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(item.isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help(L("clipboard.copy"))
            .accessibilityLabel(L("clipboard.copy"))

            Button(action: copyItem) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(didCopy ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 24, height: 24)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help(didCopy ? L("clipboard.copied") : L("clipboard.copy"))
            .accessibilityLabel(L("clipboard.copy"))

            Menu {
                Button(L("clipboard.pin"), action: onTogglePinned)
                Button(item.isSensitive ? L("clipboard.unmarkSensitive") : L("clipboard.markSensitive"), action: onToggleSensitive)
                Button(L("clipboard.editMetadata"), action: beginEditingMetadata)
                quickActions
                Button(L("clipboard.delete"), role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(.circle)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(L("clipboard.actions"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .onHover { isHovered = $0 && !isHistoryScrolling }
        .onChange(of: isHistoryScrolling) { _, isScrolling in
            if isScrolling { isHovered = false }
        }
        .anchorPreference(key: ClipboardHistoryHoverPreviewPreferenceKey.self, value: .bounds) { anchor in
            isHovered ? ClipboardHistoryHoverPreviewTarget(item: item, anchor: anchor) : nil
        }
        .controlCenterSurface(interactive: true, shape: AnyShape(.rect(cornerRadius: 14)))
        .popover(isPresented: $isEditingMetadata, arrowEdge: .trailing) {
            ClipboardHistoryMetadataEditor(
                title: $draftTitle,
                tags: $draftTags,
                note: $draftNote,
                onCancel: { isEditingMetadata = false },
                onSave: saveMetadata
            )
        }
    }

    @ViewBuilder
    private var quickActions: some View {
        switch item.content {
        case let .url(value):
            Button(L("clipboard.openURL")) { ClipboardHistoryQuickAction.openURL(value) }
        case let .files(files):
            Button(L("clipboard.revealInFinder")) { ClipboardHistoryQuickAction.revealFiles(files) }
            Button(L("clipboard.copyPath")) { _ = ClipboardHistoryQuickAction.copyPaths(files) }
        case .image:
            if let recognizedText = item.recognizedText {
                Button(L("clipboard.copyRecognizedText")) {
                    _ = ClipboardHistoryQuickAction.copyRecognizedText(recognizedText)
                }
            }
            if let url = item.recognizedURLs.first {
                Button(L("clipboard.openRecognizedQR")) { NSWorkspace.shared.open(url) }
            }
        case .pdf:
            Button(L("clipboard.copy")) { _ = ClipboardHistoryService.shared.copy(item) }
        case .text, .richText:
            EmptyView()
        }
        if !item.isSensitive, item.content.plainTextRepresentation != nil {
            Menu(L("clipboard.transform")) {
                ForEach(ClipboardTextTransform.allCases) { transform in
                    Button(L(transform.localizationKey)) { onTransform(transform) }
                }
            }
            if BuiltInPluginManager.shared.isEnabled(.translation) {
                Button(L("clipboard.translate"), action: onTranslate)
            }
        }
    }

    private func copyItem() {
        if isSelecting {
            onSelectionChanged(!isSelected)
            return
        }
        guard onCopy() else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            didCopy = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeOut(duration: 0.16)) {
                didCopy = false
            }
        }
    }

    private func beginEditingMetadata() {
        draftTitle = item.title ?? ""
        draftTags = item.tags.joined(separator: ", ")
        draftNote = item.note ?? ""
        isEditingMetadata = true
    }

    private func saveMetadata() {
        onSetTitle(draftTitle)
        onSetTags(draftTags.components(separatedBy: CharacterSet(charactersIn: ",，\n")))
        onSetNote(draftNote)
        isEditingMetadata = false
    }

    private func sourceApplicationName(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension().lastPathComponent ?? bundleID
    }

    private var previewText: String {
        if item.isSensitive { return L("clipboard.sensitiveContent") }
        switch item.content {
        case let .text(text): return text
        case let .richText(richText): return richText.plainText
        case .image: return L("clipboard.image")
        case .pdf: return L("clipboard.pdf")
        case let .url(value): return value
        case let .files(files):
            guard let first = files.first else { return L("clipboard.files") }
            let missingCount = files.filter { !$0.isAvailable }.count
            let title = files.count == 1
                ? first.displayName
                : L("clipboard.filesCount", files.count, first.displayName)
            let missingLabel = L("clipboard.filesMissing", missingCount)
            return missingCount == 0
                ? title
                : "\(title) · \(missingLabel)"
        }
    }
}

private struct ClipboardHistoryMetadataEditor: View {
    @Binding var title: String
    @Binding var tags: String
    @Binding var note: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("clipboard.editMetadata"))
                .font(.headline)
            TextField(L("clipboard.customTitle"), text: $title)
                .textFieldStyle(.roundedBorder)
            TextField(L("clipboard.tagsPlaceholder"), text: $tags)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $note)
                .frame(minHeight: 76)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if note.isEmpty {
                        Text(L("clipboard.notePlaceholder"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(11)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Spacer()
                Button(L("common.cancel"), action: onCancel)
                Button(L("common.save"), action: onSave)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct ClipboardHistoryThumbnail: View {
    let id: UUID
    let content: ClipboardHistoryContent
    let isSensitive: Bool
    @State private var cachedImageData: Data?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.045)

            if isSensitive {
                Image(systemName: "eye.slash.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                thumbnailContent
            }
        }
        .frame(
            width: ClipboardHistoryPreviewLayout.thumbnailSize.width,
            height: ClipboardHistoryPreviewLayout.thumbnailSize.height
        )
        .clipped()
        .clipShape(.rect(cornerRadius: 10))
        .task(id: id) {
            guard case let .image(data) = content, !isSensitive else { return }
            cachedImageData = await ClipboardImageThumbnailCache.shared.thumbnail(for: id, source: data)
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        switch content {
            case let .text(text):
                Text(text.prefix(2).uppercased())
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case let .richText(richText):
                Text(richText.plainText.prefix(2).uppercased())
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
            case .pdf:
                Image(systemName: "doc.richtext")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case let .image(data):
                if let image = NSImage(data: cachedImageData ?? data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: ClipboardHistoryPreviewLayout.thumbnailSize.width,
                            height: ClipboardHistoryPreviewLayout.thumbnailSize.height
                        )
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            case .url:
                Image(systemName: "link")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
            case let .files(files):
                Image(systemName: files.count == 1 ? "doc.fill" : "doc.on.doc.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
        }
    }
}

private struct ClipboardHistoryHoverPreview: View {
    let item: ClipboardHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: item.isPinned ? "pin.fill" : "doc.on.clipboard")
                    .foregroundStyle(item.isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(item.capturedAt, format: .dateTime.hour().minute())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "eye")
                    .foregroundStyle(.tertiary)
            }

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
        }
        .padding(12)
        .frame(
            width: ClipboardHistoryPreviewLayout.hoverPreviewSize.width,
            height: ClipboardHistoryPreviewLayout.hoverPreviewSize.height
        )
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }

    @ViewBuilder
    private var previewContent: some View {
        if item.isSensitive {
            ContentUnavailableView(
                L("clipboard.sensitiveContent"),
                systemImage: "eye.slash.fill"
            )
        } else {
            regularPreviewContent
        }
    }

    @ViewBuilder
    private var regularPreviewContent: some View {
        switch item.content {
        case let .text(text):
            Text(text)
                .font(.body)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        case let .richText(richText):
            Text(richText.plainText)
                .font(.body)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        case .pdf:
            Label(L("clipboard.pdf"), systemImage: "doc.richtext")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .image(data):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                ContentUnavailableView(
                    L("clipboard.image"),
                    systemImage: "photo"
                )
            }
        case let .url(value):
            Text(value)
                .font(.body)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        case let .files(files):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(files) { file in
                    Label(file.displayName, systemImage: "doc")
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
        }
    }
}

/// 可嵌入设置页或菜单栏 Popover 的剪贴板历史内容。
struct ClipboardHistoryQuickAccessView: View {
    let onCopy: () -> Void
    let selectionAction: ClipboardHistoryAction

    @State private var historyService = ClipboardHistoryService.shared
    @State private var snippetService = ClipboardSnippetService.shared

    init(
        selectionAction: ClipboardHistoryAction = .copy,
        onCopy: @escaping () -> Void = {}
    ) {
        self.selectionAction = selectionAction
        self.onCopy = onCopy
    }

    var body: some View {
        ClipboardHistoryPopover(
            items: historyService.items,
            onCopy: { item in
                if historyService.perform(item, action: selectionAction) {
                    onCopy()
                }
            },
            onPerformAction: { item, action in
                if historyService.perform(item, action: action) {
                    onCopy()
                }
            },
            onTogglePinned: historyService.togglePinned,
            onRemove: historyService.remove,
            onClearHistory: historyService.clearHistory,
            onClearClipboard: clearClipboard,
            copyFeedback: historyService.copyFeedback,
            canUndo: historyService.canUndoLastRemoval,
            onUndo: { _ = historyService.undoLastRemoval() },
            snippetGroups: snippetService.groups,
            snippets: snippetService.snippets,
            onCopySnippet: copySnippet,
            onTransform: { item, transform in
                if historyService.copyTransformed(item, transform: transform) {
                    onCopy()
                }
            },
            onTranslate: { item in
                guard let text = item.content.plainTextRepresentation else { return }
                TranslationWindowController.shared.show(text: text)
                onCopy()
            }
        )
        .task {
            await historyService.loadPersistedHistory()
            historyService.refresh()
        }
    }

    private func clearClipboard() {
        historyService.clearSystemClipboard()
    }

    private func copySnippet(_ snippet: ClipboardSnippet) {
        let renderedContent = ClipboardSnippetTemplate.render(
            snippet.content,
            clipboardText: NSPasteboard.general.string(forType: .string)
        )
        if historyService.perform(.text(renderedContent), action: selectionAction) {
            onCopy()
        }
    }
}
