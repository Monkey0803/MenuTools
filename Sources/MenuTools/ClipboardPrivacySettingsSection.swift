import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 剪贴板隐私设置：暂停记录与前台 App 排除规则。
struct ClipboardPrivacySettingsSection: View {
    @Bindable var historyService: ClipboardHistoryService
    @State private var snippetService = ClipboardSnippetService.shared
    @State private var keywordInput = ""
    @State private var archivePassphrase = ""
    @State private var archiveStatus: ClipboardArchiveOperationStatus?
    @State private var isArchiveOperationInProgress = false
    @State private var syncFilePath = UserDefaults.standard.string(forKey: "clipboard.syncFilePath")

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

            Divider()

            Text(L("clipboard.sensitiveRules"))
                .font(.subheadline.weight(.medium))
            Toggle(L("clipboard.sensitive.passwordManagers"), isOn: ruleBinding(\.passwordManagersEnabled))
            Toggle(L("clipboard.sensitive.verificationCodes"), isOn: ruleBinding(\.verificationCodesEnabled))
            Toggle(L("clipboard.sensitive.bankCards"), isOn: ruleBinding(\.bankCardsEnabled))

            HStack(spacing: 8) {
                TextField(L("clipboard.sensitive.keywordPlaceholder"), text: $keywordInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addKeyword)
                Button(L("clipboard.sensitive.addKeyword"), action: addKeyword)
                    .disabled(keywordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !historyService.sensitiveRules.keywords.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
                    ForEach(historyService.sensitiveRules.keywords, id: \.self) { keyword in
                        Button {
                            var rules = historyService.sensitiveRules
                            rules.keywords.removeAll { $0 == keyword }
                            historyService.setSensitiveRules(rules)
                        } label: {
                            Label(keyword, systemImage: "xmark")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Text(L("clipboard.sensitiveRules.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text(L("clipboard.archive"))
                .font(.subheadline.weight(.medium))
            SecureField(L("clipboard.archive.passphrase"), text: $archivePassphrase)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button(action: exportArchive) {
                    Label(L("clipboard.archive.export"), systemImage: "lock.doc")
                }
                Button(action: importArchive) {
                    Label(L("clipboard.archive.import"), systemImage: "lock.open")
                }
                if isArchiveOperationInProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .disabled(isArchiveOperationInProgress || archivePassphrase.isEmpty)

            Text(L("clipboard.archive.description"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let persistenceErrorMessage = historyService.persistenceErrorMessage {
                Label(persistenceErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let archiveStatus {
                Text(archiveStatus.message)
                    .font(.caption)
                    .foregroundStyle(archiveStatus.isSuccess ? .green : .red)
            }

            HStack(spacing: 8) {
                Button(L("clipboard.sync.chooseFolder"), action: chooseSyncFolder)
                Button(L("clipboard.sync.now"), action: synchronizeSharedFile)
                    .disabled(syncFilePath == nil || archivePassphrase.isEmpty || isArchiveOperationInProgress)
                if let syncFilePath {
                    Text(URL(fileURLWithPath: syncFilePath).deletingLastPathComponent().lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(syncFilePath)
                }
            }

            Text(L("clipboard.sync.description"))
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private func ruleBinding(_ keyPath: WritableKeyPath<ClipboardSensitiveRules, Bool>) -> Binding<Bool> {
        Binding(
            get: { historyService.sensitiveRules[keyPath: keyPath] },
            set: { enabled in
                var rules = historyService.sensitiveRules
                rules[keyPath: keyPath] = enabled
                historyService.setSensitiveRules(rules)
            }
        )
    }

    private func addKeyword() {
        let keyword = keywordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        var rules = historyService.sensitiveRules
        guard !rules.keywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) else {
            keywordInput = ""
            return
        }
        rules.keywords.append(keyword)
        historyService.setSensitiveRules(rules)
        keywordInput = ""
    }

    private func exportArchive() {
        guard !archivePassphrase.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = L("clipboard.archive.export")
        panel.allowedContentTypes = [archiveContentType]
        panel.nameFieldStringValue = "MenuTools-Clipboard-\(Date().formatted(.iso8601.year().month().day())).mtclip"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let passphrase = archivePassphrase
        let document = ClipboardArchiveDocument.current(
            historyItems: historyService.items,
            snippetGroups: snippetService.groups,
            snippets: snippetService.snippets
        )
        isArchiveOperationInProgress = true
        archiveStatus = nil
        Task { @MainActor in
            defer {
                isArchiveOperationInProgress = false
                archivePassphrase = ""
            }
            do {
                try await Task.detached(priority: .utility) {
                    let encrypted = try ClipboardArchiveCrypto.encrypt(document, passphrase: passphrase)
                    try encrypted.write(to: url, options: .atomic)
                }.value
                archiveStatus = .success(L("clipboard.archive.exportSuccess"))
            } catch {
                archiveStatus = .failure(error.localizedDescription)
            }
        }
    }

    private func importArchive() {
        guard !archivePassphrase.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = L("clipboard.archive.import")
        panel.allowedContentTypes = [archiveContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let passphrase = archivePassphrase
        isArchiveOperationInProgress = true
        archiveStatus = nil
        Task { @MainActor in
            defer {
                isArchiveOperationInProgress = false
                archivePassphrase = ""
            }
            do {
                let document = try await Task.detached(priority: .utility) {
                    let encrypted = try Data(contentsOf: url)
                    return try ClipboardArchiveCrypto.decrypt(encrypted, passphrase: passphrase)
                }.value
                historyService.importItems(document.historyItems)
                snippetService.replaceImported(
                    groups: document.snippetGroups,
                    snippets: document.snippets
                )
                archiveStatus = .success(L("clipboard.archive.importSuccess"))
            } catch {
                archiveStatus = .failure(error.localizedDescription)
            }
        }
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.title = L("clipboard.sync.chooseFolder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let syncFilePath {
            panel.directoryURL = URL(fileURLWithPath: syncFilePath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        let fileURL = folderURL.appendingPathComponent("MenuTools-Clipboard.mtclipsync")
        syncFilePath = fileURL.path
        UserDefaults.standard.set(fileURL.path, forKey: "clipboard.syncFilePath")
    }

    private func synchronizeSharedFile() {
        guard !archivePassphrase.isEmpty,
              let syncFilePath else { return }
        let passphrase = archivePassphrase
        let fileURL = URL(fileURLWithPath: syncFilePath)
        let local = ClipboardArchiveDocument.current(
            historyItems: historyService.items.filter(\.isPinned),
            snippetGroups: snippetService.groups,
            snippets: snippetService.snippets
        )
        isArchiveOperationInProgress = true
        archiveStatus = nil
        Task { @MainActor in
            defer {
                isArchiveOperationInProgress = false
                archivePassphrase = ""
            }
            do {
                let merged = try await Task.detached(priority: .utility) {
                    try ClipboardSharedFileSync.synchronize(
                        local: local,
                        at: fileURL,
                        passphrase: passphrase
                    )
                }.value
                historyService.importItems(merged.historyItems)
                snippetService.replaceImported(groups: merged.snippetGroups, snippets: merged.snippets)
                archiveStatus = .success(L("clipboard.sync.success"))
            } catch {
                archiveStatus = .failure(error.localizedDescription)
            }
        }
    }

    private var archiveContentType: UTType {
        UTType(filenameExtension: "mtclip") ?? .data
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

private enum ClipboardArchiveOperationStatus {
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case let .success(message), let .failure(message): message
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
