import SwiftUI

/// 剪贴板历史的自动清理和复制后粘贴设置。
struct ClipboardHistoryManagementSettingsSection: View {
    @Bindable var historyService: ClipboardHistoryService

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

            Divider()

            Toggle(L("clipboard.autoPaste"), isOn: Binding(
                get: { historyService.autoPasteAfterCopy },
                set: { historyService.setAutoPasteAfterCopy($0) }
            ))
            .toggleStyle(.switch)

            Text(L("clipboard.autoPasteDescription"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 14))
    }
}
