import AppKit
import SwiftUI

/// 系统存储设置页：磁盘容量总览和可审计的目录分析。
///
/// 这里不尝试伪造 macOS 的“系统数据”分类；只展示 MenuTools 能可靠扫描的用户目录，
/// 并且仅对经过审核的 DerivedData 暴露删除动作。
struct SystemStorageSettingsView: View {
    @State private var storage = StorageAnalysisService()
    @State private var cleanupPreview: StorageCleanupPreview?
    @State private var feedback: String?

    var body: some View {
        Form {
            if let snapshot = storage.snapshot {
                overviewSection(snapshot.volume)
                analyzedDirectoriesSection(snapshot.entries)
            } else {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("storage.loading"))
                            .foregroundStyle(.secondary)
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
                NSWorkspace.shared.activateFileViewerSelecting([preview.directoryURL])
            }
            Button(L("common.cancel"), role: .cancel) {
                cleanupPreview = nil
            }
            Button(L("storage.clean"), role: .destructive) {
                cleanupPreview = nil
                Task { await clean(preview) }
            }
        } message: { preview in
            Text(L("storage.confirm.detail", preview.path, formatted(preview.reclaimableBytes)))
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

                    if entry.category.isSafeToClean, entry.bytes > 0 {
                        Button(role: .destructive) {
                            cleanupPreview = storage.cleanupPreview(for: entry)
                        } label: {
                            Label(
                                storage.cleaningCategory == entry.category
                                    ? L("storage.cleaning")
                                    : L("storage.clean"),
                                systemImage: "trash"
                            )
                        }
                        .disabled(storage.cleaningCategory != nil)
                    } else if !entry.category.isSafeToClean {
                        Text(L("storage.manualReview"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
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
                .accessibilityLabel(L("storage.refresh"))
            }
        }
    }

    private func clean(_ preview: StorageCleanupPreview) async {
        do {
            try await storage.clean(preview.category)
            feedback = L("status.freed", formatted(preview.reclaimableBytes))
        } catch {
            feedback = error.localizedDescription
        }
    }

    private func formatted(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
