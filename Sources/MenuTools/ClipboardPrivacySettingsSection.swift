import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 剪贴板隐私设置：暂停记录与前台 App 排除规则。
struct ClipboardPrivacySettingsSection: View {
    @Bindable var historyService: ClipboardHistoryService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(L("clipboard.privacy"), systemImage: "hand.raised")
                    .font(.headline)
                Spacer()
                Toggle(L("clipboard.pauseRecording"), isOn: Binding(
                    get: { historyService.isRecordingPaused },
                    set: { historyService.setRecordingPaused($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Text(L("clipboard.pauseRecording.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text(L("clipboard.excludedApps"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button(L("clipboard.excludeApp"), action: chooseExcludedApplication)
            }

            Text(L("clipboard.excludedApps.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if historyService.excludedBundleIDs.isEmpty {
                Text(L("clipboard.excludedApps.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(historyService.excludedBundleIDs, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        excludedApplicationIcon(for: bundleID)
                            .frame(width: 18, height: 18)
                        Text(excludedApplicationName(for: bundleID))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            historyService.removeExcludedBundleID(bundleID)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("clipboard.excludeApp.remove"))
                        .accessibilityLabel(L("clipboard.excludeApp.remove"))
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 14))
    }

    private func chooseExcludedApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = L("clipboard.excludeApp")
        panel.begin { response in
            guard response == .OK,
                  let url = panel.url,
                  let bundleID = Bundle(url: url)?.bundleIdentifier else {
                return
            }
            historyService.addExcludedBundleID(bundleID)
        }
    }

    private func excludedApplicationName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return url.deletingPathExtension().lastPathComponent
    }

    @ViewBuilder
    private func excludedApplicationIcon(for bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
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
