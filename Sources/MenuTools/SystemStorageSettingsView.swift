import AppKit
import SwiftUI

/// 系统存储设置页：磁盘容量、可分析目录及只读整理建议。
/// 不伪造 macOS 的“系统数据”分类，只显示 MenuTools 可验证的用户目录。
struct SystemStorageSettingsView: View {
    @State private var storage = StorageAnalysisService.shared
    @State private var cleanupPreview: StorageCleanupPreview?
    @State private var selectedDeveloperItemIDs: Set<String> = []
    @State private var feedback: String?
    @State private var largeFileMode: StorageLargeFileMode = .largest

    var body: some View {
        Form {
            scanStateSection

            if let snapshot = storage.snapshot {
                overviewSection(snapshot.volume)
                analyzedDirectoriesSection(snapshot.sortedEntries)
                recommendationsSection(storage.recommendations)
                simulatorSection(snapshot.simulatorItems)
                largeFilesSection(snapshot.largeFiles)
            } else if storage.isLoading {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("storage.loading"))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Text(storage.lastScanWasCancelled ? L("storage.scanCancelled") : L("storage.unavailable"))
                        .foregroundStyle(.secondary)
                    Button(L("storage.refresh")) {
                        storage.refresh()
                    }
                }
            }

            Section {
                Text(L("storage.module.scope"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label(L("storage.module.about"), systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { storage.refresh() }
        .alert(
            L("storage.confirm.title"),
            isPresented: Binding(
                get: { cleanupPreview != nil },
                set: { if !$0 { cleanupPreview = nil } }
            ),
            presenting: cleanupPreview
        ) { preview in
            Button(L("storage.openFinder")) {
                openInFinder(preview.directoryURL)
            }
            Button(L("common.cancel"), role: .cancel) {
                cleanupPreview = nil
            }
            Button(L("storage.clean"), role: .destructive) {
                cleanupPreview = nil
                Task { await clean(preview) }
            }
        } message: { preview in
            if preview.items.isEmpty {
                Text(L("storage.confirm.detail", preview.path, formatted(preview.reclaimableBytes)))
            } else {
                Text(L(
                    "storage.confirm.selectionDetail",
                    preview.items.count,
                    formatted(preview.reclaimableBytes),
                    preview.items.prefix(3).map(\.relativePath).joined(separator: "\n")
                ))
            }
        }
    }

    @ViewBuilder
    private func simulatorSection(_ items: [CoreSimulatorStorageItem]) -> some View {
        if !items.isEmpty {
            Section {
                Text(L("storage.simulator.warning"))
                    .font(.caption).foregroundStyle(.orange)
                ForEach(items) { item in
                    HStack {
                        Label(L(item.kind.titleKey), systemImage: item.kind.symbol)
                        Spacer()
                        Text(formatted(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        Button(L("storage.openFinder")) { openInFinder(item.directoryURL) }.controlSize(.small)
                    }
                }
            } header: { Label(L("storage.simulator.title"), systemImage: "cpu") }
        }
    }

    @ViewBuilder
    private func largeFilesSection(_ files: [StorageLargeFile]) -> some View {
        let visible = files.filter { $0.mode == largeFileMode }
        if !visible.isEmpty {
            Section {
                Picker(L("storage.largeFiles.filter"), selection: $largeFileMode) {
                    ForEach(StorageLargeFileMode.allCases, id: \.rawValue) { mode in Text(L(mode.titleKey)).tag(mode) }
                }.pickerStyle(.segmented)
                ForEach(visible) { file in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text(file.fileURL.lastPathComponent).lineLimit(1)
                            Text("\(L(file.category.titleKey)) · \(formatted(file.date))").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatted(file.bytes)).font(.caption).monospacedDigit()
                        Button { openInFinder(file.fileURL) } label: { Image(systemName: "folder") }.buttonStyle(.plain)
                    }
                }
                Text(L("storage.largeFiles.dateRule")).font(.caption).foregroundStyle(.secondary)
                Text(L("storage.largeFiles.readOnly")).font(.caption).foregroundStyle(.secondary)
            } header: { Label(L("storage.largeFiles.title"), systemImage: "doc.richtext") }
        }
    }

    @ViewBuilder
    private var scanStateSection: some View {
        Section {
            if storage.isLoading, let progress = storage.scanProgress {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        ProgressView(value: progress.fractionCompleted)
                            .tint(.indigo)
                        Text(L(
                            "storage.scanning",
                            progress.currentCategory.map { L($0.titleKey) } ?? L("storage.loading")
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("\(progress.completedCount) / \(progress.totalCount)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button(L("storage.cancelScan")) {
                            storage.cancelRefresh()
                        }
                        .controlSize(.small)
                    }
                }
            } else if let lastScanDate = storage.lastScanDate {
                Text(L("storage.lastScan", formatted(lastScanDate)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func overviewSection(_ volume: StorageVolumeOverview) -> some View {
        Section {
            ProgressView(value: volume.usedRatio)
                .tint(.indigo)
            LabeledContent(L("storage.used"), value: formatted(volume.usedBytes))
            LabeledContent(L("storage.free"), value: formatted(volume.availableBytes))
            LabeledContent(L("storage.total"), value: formatted(volume.totalBytes))
        } header: {
            Label(L("storage.module.overview"), systemImage: "internaldrive.fill")
        }
    }

    @ViewBuilder
    private func analyzedDirectoriesSection(_ entries: [StorageDirectoryInfo]) -> some View {
        Section {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: entry.category.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(L(entry.category.titleKey))
                        Spacer()
                        Text(entry.exists ? formatted(entry.bytes) : "--")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Text(L("storage.\(entry.category.rawValue).detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let issue = entry.accessIssue {
                        Text(L(issue.localizedKey))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack(spacing: 10) {
                        Button(L("storage.openFinder")) {
                            openInFinder(entry.category.directoryURL)
                        }
                        .controlSize(.small)

                    if entry.category.supportsDetailedCleanup, entry.bytes > 0 {
                        developerItemsSection(for: entry.category)
                    } else if entry.category.requiresManualReview {
                            Text(L("storage.manualReview"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 3)
            }

            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Label(L("storage.module.analyzedDirectories"), systemImage: "folder")
                Spacer()
                Button {
                    storage.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(storage.isLoading)
                .accessibilityLabel(L("storage.refresh"))
            }
        }
    }

    @ViewBuilder
    private func developerItemsSection(for category: StorageCategory) -> some View {
        let items = storage.snapshot?.developerItems(for: category) ?? []
        DisclosureGroup {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Toggle("", isOn: selectionBinding(for: item))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .lineLimit(1)
                        Text(item.relativePath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let lastModified = item.lastModified {
                            Text(L("storage.item.modified", formatted(lastModified)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(formatted(item.bytes))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button {
                        openInFinder(item.directoryURL)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("storage.openFinder"))
                }
                .padding(.vertical, 2)
            }

            let selectedItems = items.filter { selectedDeveloperItemIDs.contains($0.id) }
            if !selectedItems.isEmpty {
                HStack {
                    Text(L("storage.selectedItems", selectedItems.count, formatted(selectedItems.reduce(0) { $0 + $1.bytes })))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("storage.cleanSelected"), role: .destructive) {
                        cleanupPreview = storage.cleanupPreview(for: selectedItems)
                    }
                    .controlSize(.small)
                    .disabled(storage.cleaningCategory != nil)
                }
                .padding(.top, 4)
            }
        } label: {
            Label(L("storage.developerItems", items.count), systemImage: "list.bullet")
                .font(.caption)
        }
    }

    @ViewBuilder
    private func recommendationsSection(_ recommendations: [StorageRecommendation]) -> some View {
        if !recommendations.isEmpty {
            Section {
                ForEach(recommendations) { recommendation in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L(recommendation.kind.titleKey))
                            Text(L(
                                "storage.recommendation.detail",
                                "\(L(recommendation.category.titleKey)) · \(formatted(recommendation.bytes))",
                                formatted(recommendation.lastModified)
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("storage.openFinder")) {
                            openInFinder(recommendation.category.directoryURL)
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Label(L("storage.recommendations"), systemImage: "lightbulb")
            }
        }
    }

    private func clean(_ preview: StorageCleanupPreview) async {
        do {
            guard !preview.items.isEmpty else { return }
            try await storage.clean(preview.items)
            selectedDeveloperItemIDs.subtract(preview.items.map(\.id))
            feedback = L("status.freed", formatted(preview.reclaimableBytes))
        } catch {
            feedback = error.localizedDescription
        }
    }

    private func selectionBinding(for item: StorageDeveloperItem) -> Binding<Bool> {
        Binding(
            get: { selectedDeveloperItemIDs.contains(item.id) },
            set: { isSelected in
                if isSelected {
                    selectedDeveloperItemIDs.insert(item.id)
                } else {
                    selectedDeveloperItemIDs.remove(item.id)
                }
            }
        )
    }

    private func openInFinder(_ directoryURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
    }

    private func formatted(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
