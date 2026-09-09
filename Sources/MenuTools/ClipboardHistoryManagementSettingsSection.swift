import SwiftUI

/// 剪贴板历史的自动清理和复制后粘贴设置。
struct ClipboardHistoryManagementSettingsSection: View {
    @Bindable var historyService: ClipboardHistoryService
    @State private var isAccessibilityTrusted = ClipboardAccessibilityPermission.isTrusted

    private let retentionOptions = [0, 1, 7, 30, 90]
    private let storageOptions = [0, 10, 50, 100, 500]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("clipboard.management"), systemImage: "clock.badge.checkmark")
                .font(.headline)

            HStack {
                Text(L("clipboard.retentionDays"))
                Spacer()
                Picker(L("clipboard.retentionDays"), selection: Binding(
                    get: { historyService.retentionDays },
                    set: { historyService.setRetentionDays($0) }
                )) {
                    ForEach(retentionOptions, id: \.self) { days in
                        Text(days == 0 ? L("clipboard.unlimited") : L("clipboard.retentionDaysValue", days))
                            .tag(days)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            HStack {
                Text(L("clipboard.storageLimit"))
                Spacer()
                Picker(L("clipboard.storageLimit"), selection: Binding(
                    get: { historyService.storageLimitBytes == .max ? 0 : historyService.storageLimitBytes / 1_024 / 1_024 },
                    set: { historyService.setStorageLimitMegabytes($0) }
                )) {
                    ForEach(storageOptions, id: \.self) { megabytes in
                        Text(megabytes == 0 ? L("clipboard.unlimited") : L("clipboard.storageLimitValue", megabytes))
                            .tag(megabytes)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Text(L("clipboard.cleanupDescription"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let summary = historyService.lastCleanupSummary {
                Label(
                    L(
                        "clipboard.cleanupSummary",
                        summary.removedCount,
                        ByteCountFormatter.string(fromByteCount: Int64(summary.reclaimedBytes), countStyle: .file),
                        summary.preservedPinnedCount
                    ),
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text(L("clipboard.primaryAction"))
                Spacer()
                Picker(L("clipboard.primaryAction"), selection: Binding(
                    get: { historyService.primaryAction },
                    set: { historyService.setPrimaryAction($0) }
                )) {
                    ForEach(ClipboardPrimaryAction.allCases) { action in
                        Text(L(action.localizationKey)).tag(action)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Text(L("clipboard.autoPasteDescription"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if historyService.primaryAction == .paste {
                HStack(spacing: 8) {
                    Image(systemName: isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isAccessibilityTrusted ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                    Text(isAccessibilityTrusted ? L("shortcut.permission.granted") : L("shortcut.permission"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !isAccessibilityTrusted {
                        Button(L("shortcut.openPermission")) {
                            _ = ClipboardAccessibilityPermission.openSettings()
                            isAccessibilityTrusted = ClipboardAccessibilityPermission.isTrusted
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 14))
        .onAppear {
            isAccessibilityTrusted = ClipboardAccessibilityPermission.isTrusted
        }
    }
}
