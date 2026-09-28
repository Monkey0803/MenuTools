import SwiftUI

/// 剪贴板历史的自动清理和复制后粘贴设置。
struct ClipboardHistoryManagementSettingsSection: View {
    @Bindable var historyService: ClipboardHistoryService
    @State private var isAccessibilityTrusted = ClipboardAccessibilityPermission.isTrusted

    @State private var isPerTypeRetentionExpanded = false

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
                    ForEach(ClipboardRetentionOptions.dayChoices, id: \.self) { days in
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
                    ForEach(ClipboardRetentionOptions.storageChoices, id: \.self) { megabytes in
                        Text(megabytes == 0 ? L("clipboard.unlimited") : L("clipboard.storageLimitValue", megabytes))
                            .tag(megabytes)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            HStack {
                Text(L("clipboard.limit"))
                Spacer()
                Picker(L("clipboard.limit"), selection: Binding(
                    get: { ClipboardHistoryLimit(rawValue: historyService.limit) ?? .fifty },
                    set: { limit in historyService.setLimit(limit) }
                )) {
                    ForEach(ClipboardHistoryLimit.allCases) { limit in
                        Text(L("clipboard.limitValue", limit.rawValue)).tag(limit)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            // 实际占用此前完全不可见：唯一会自动发生却看不到的机制。
            HStack(spacing: 8) {
                Text(L("clipboard.storageUsage"))
                Spacer()
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(historyService.storageUsageBytes),
                    countStyle: .file
                ))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                Button(L("clipboard.cleanUpNow")) {
                    historyService.cleanUpNow()
                }
                .controlSize(.small)
            }

            Text(L("clipboard.storageUsage.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(L("clipboard.cleanupDescription"))
                .font(.caption)
                .foregroundStyle(.secondary)

            // 按内容类型分别保留：能力早已实现并持久化，此前没有任何界面入口。
            DisclosureGroup(isExpanded: $isPerTypeRetentionExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ClipboardHistoryContentType.allCases, id: \.self) { type in
                        HStack {
                            Text(L(type.titleKey))
                            Spacer()
                            Picker(L(type.titleKey), selection: Binding(
                                get: { historyService.retentionDays(for: type) },
                                set: { historyService.setRetentionDays($0, for: type) }
                            )) {
                                ForEach(ClipboardRetentionOptions.dayChoices, id: \.self) { days in
                                    Text(days == 0
                                        ? L("clipboard.unlimited")
                                        : L("clipboard.retentionDaysValue", days))
                                        .tag(days)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(L("clipboard.retentionByType"))
                    .font(.callout)
            }

            if isPerTypeRetentionExpanded {
                Text(L("clipboard.retentionByType.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
            historyService.refreshStorageUsage()
        }
    }
}
