import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口统一尺寸（各 Tab 一致，避免切换时窗口重置闪烁）
enum SettingsLayout {
    static let width: CGFloat = 480
    static let height: CGFloat = 580
}

/// 设置窗口（⌘, / 面板齿轮按钮打开）：分标签容纳通用与右键工具
struct SettingsView: View {
    @AppStorage(SettingsKey.appLanguage) private var appLanguage = AppLanguage.system.rawValue

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label(L("settings.tab.general"), systemImage: "gearshape") }
            RightClickToolsView()
                .tabItem { Label(L("settings.tab.rightClick"), systemImage: "contextualmenu.and.cursorarrow") }
            ScrollSettingsView()
                .tabItem { Label(L("settings.tab.scroll"), systemImage: "computermouse") }
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .id(appLanguage)   // 切换语言时整体重建，连 Tab 标签一起刷新
    }
}

/// 通用设置页
struct GeneralSettingsView: View {
    @AppStorage(SettingsKey.menuBarIcon) private var menuBarIcon = MenuBarIcon.default.rawValue
    @AppStorage(SettingsKey.menuBarShowTitle) private var showMenuBarTitle = false
    @AppStorage(SettingsKey.togglesShowTitle) private var togglesShowTitle = false
    @AppStorage(SettingsKey.preferredTerminal) private var preferredTerminal = TerminalApp.systemDefault.rawValue
    @AppStorage(SettingsKey.autoCheckUpdate) private var autoCheckUpdate = true
    @AppStorage(SettingsKey.appLanguage) private var appLanguage = AppLanguage.system.rawValue

    @State private var isCheckingUpdate = false
    @State private var checkResult: String?
    @State private var availableUpdate: UpdateInfo?
    @State private var updateDownloadService = UpdateDownloadService(
        downloader: URLSessionUpdatePackageDownloader(),
        opener: NSWorkspaceUpdatePackageOpener()
    )
    @State private var updateDownloadState: UpdateDownloadState = .idle
    @State private var isConfirmingPackageOpen = false
    @State private var launchAtLogin = LoginItemService.isEnabled
    @State private var backupStatus: BackupStatus?
    @State private var isBackupOperationInProgress = false

    private enum BackupStatus {
        case success(String)
        case failure(String)

        var message: String {
            switch self {
            case .success(let message), .failure(let message): return message
            }
        }

        var isSuccess: Bool {
            switch self {
            case .success: return true
            case .failure: return false
            }
        }
    }

    var body: some View {
        Form {
            Section(L("settings.section.general")) {
                Toggle(isOn: $launchAtLogin) {
                    Text(L("settings.launchAtLogin"))
                    Text(L("settings.launchAtLogin.desc"))
                }
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        try LoginItemService.setEnabled(newValue)
                    } catch {
                        launchAtLogin = LoginItemService.isEnabled
                    }
                }
            }

            Section(L("settings.section.icon")) {
                Picker(L("settings.menuBar.display"), selection: $showMenuBarTitle) {
                    Text(L("settings.menuBar.iconOnly")).tag(false)
                    Text(L("settings.menuBar.iconTitle")).tag(true)
                }
                .pickerStyle(.segmented)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(MenuBarIcon.allCases) { icon in
                        iconOption(icon)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(L("settings.section.panel")) {
                Picker(L("settings.toggles.display"), selection: $togglesShowTitle) {
                    Text(L("settings.menuBar.iconOnly")).tag(false)
                    Text(L("settings.menuBar.iconTitle")).tag(true)
                }
                .pickerStyle(.segmented)
            }

            Section(L("settings.section.language")) {
                Picker(L("settings.language.label"), selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
            }

            Section(L("settings.section.terminal")) {
                Picker(L("settings.terminal.desc"), selection: $preferredTerminal) {
                    ForEach(TerminalApp.installed) { app in
                        Text(app.displayName).tag(app.rawValue)
                    }
                }
            }

            Section(L("settings.section.update")) {
                Toggle(isOn: $autoCheckUpdate) {
                    Text(L("settings.autoCheck"))
                    Text(L("settings.autoCheck.desc"))
                }

                LabeledContent(L("settings.currentVersion"), value: "v\(UpdateCheckerService.currentVersion)")

                LabeledContent {
                    HStack(spacing: 10) {
                        if let result = checkResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(availableUpdate == nil ? .secondary : .primary)
                        }
                        if case let .downloading(progress) = updateDownloadState {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("update.downloading"))
                                    .font(.caption)
                                ProgressView(value: progress)
                                Text(L("update.progress", Int(progress * 100)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Button(L("update.cancel")) {
                                cancelUpdateDownload()
                            }
                            .disabled(!isDownloadingUpdate)
                        } else if case .completed = updateDownloadState {
                            Text(L("update.completed"))
                                .font(.caption)
                                .foregroundStyle(.green)
                            Button(L("update.open")) {
                                isConfirmingPackageOpen = true
                            }
                        } else if isCheckingUpdate {
                            ProgressView()
                                .controlSize(.small)
                        } else if let update = availableUpdate {
                            Button(L("settings.download", update.version)) {
                                startUpdateDownload(update)
                            }
                            .disabled(isDownloadingUpdate)
                        } else {
                            Button(L("settings.checkNow")) {
                                checkForUpdate()
                            }
                            .disabled(isDownloadingUpdate)
                        }
                    }
                } label: {
                    Text(L("settings.manualCheck"))
                }
            }

            Section(L("settings.section.backup")) {
                HStack(spacing: 10) {
                    Button {
                        exportBackup()
                    } label: {
                        Label(L("settings.backup.export"), systemImage: "square.and.arrow.up")
                    }

                    Button {
                        importBackup()
                    } label: {
                        Label(L("settings.backup.import"), systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(isBackupOperationInProgress)

                if let backupStatus {
                    Text(backupStatus.message)
                        .font(.caption)
                        .foregroundStyle(backupStatus.isSuccess ? .green : .red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .navigationTitle(L("settings.title"))
        .task {
            await observeUpdateDownload()
        }
        .alert(L("update.confirmOpen.title"), isPresented: $isConfirmingPackageOpen) {
            Button(L("update.open")) {
                _ = updateDownloadService.openCompletedPackage()
                updateDownloadState = updateDownloadService.state
            }
            Button(L("update.cancel"), role: .cancel) {}
        } message: {
            Text(L("update.confirmOpen.message"))
        }
    }

    private func iconOption(_ icon: MenuBarIcon) -> some View {
        let isSelected = menuBarIcon == icon.rawValue
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                menuBarIcon = icon.rawValue
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon.rawValue)
                    .font(.body)
                    .symbolEffect(.bounce, value: isSelected)
                Text(icon.displayName)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), lineWidth: 1)
        )
    }

    private func checkForUpdate() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        checkResult = nil
        Task {
            do {
                let update = try await UpdateCheckerService.check()
                isCheckingUpdate = false
                if let update {
                    availableUpdate = update
                    checkResult = L("settings.found", update.version)
                } else {
                    checkResult = L("settings.latest")
                }
            } catch {
                isCheckingUpdate = false
                checkResult = L("settings.checkFailed", error.localizedDescription)
            }
        }
    }

    private var isDownloadingUpdate: Bool {
        if case .downloading = updateDownloadState { return true }
        return false
    }

    private func startUpdateDownload(_ update: UpdateInfo) {
        guard !isDownloadingUpdate else { return }
        _ = updateDownloadService.start(update: update)
        updateDownloadState = updateDownloadService.state
        handleUpdateDownloadState(updateDownloadState)
    }

    private func cancelUpdateDownload() {
        guard updateDownloadService.cancel() else { return }
        updateDownloadState = updateDownloadService.state
        handleUpdateDownloadState(updateDownloadState)
    }

    /// 轮询服务状态，将非 ObservableObject 的下载服务状态同步到视图。
    private func observeUpdateDownload() async {
        while !Task.isCancelled {
            let state = updateDownloadService.state
            if state != updateDownloadState {
                updateDownloadState = state
                handleUpdateDownloadState(state)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func handleUpdateDownloadState(_ state: UpdateDownloadState) {
        switch state {
        case .idle, .downloading:
            break
        case .completed:
            checkResult = L("update.completed")
        case let .failed(error):
            checkResult = updateDownloadErrorMessage(error)
        }
    }

    private func updateDownloadErrorMessage(_ error: UpdateDownloadError) -> String {
        switch error {
        case .unsupportedFileType:
            return L("update.unsupportedPackage")
        case .openFailed:
            return L("update.openFailed")
        case .cancelled:
            return L("update.cancelled")
        case .invalidURL, .alreadyDownloading, .downloadFailed, .downloadFailedWithReason:
            return L("update.downloadFailed")
        }
    }

    private func exportBackup() {
        guard !isBackupOperationInProgress else { return }
        isBackupOperationInProgress = true
        defer { isBackupOperationInProgress = false }

        let panel = NSSavePanel()
        panel.title = L("settings.backup.export")
        panel.allowedContentTypes = [backupContentType]
        panel.nameFieldStringValue = L(
            "settings.backup.defaultFilename",
            UpdateCheckerService.currentVersion
        )

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try AppBackupService.export(
                to: url,
                userDefaults: .standard,
                rightClick: RightClickConfigStore.load(),
                appVersion: UpdateCheckerService.currentVersion,
                createdAt: Date()
            )
            backupStatus = .success(L("settings.backup.exportSuccess"))
        } catch {
            backupStatus = .failure(L("settings.backup.writeFailed"))
        }
    }

    private func importBackup() {
        guard !isBackupOperationInProgress else { return }
        isBackupOperationInProgress = true
        defer { isBackupOperationInProgress = false }

        let panel = NSOpenPanel()
        panel.title = L("settings.backup.import")
        panel.allowedContentTypes = [backupContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let document: AppBackupDocument
        do {
            document = try AppBackupService.importDocument(from: url)
        } catch {
            backupStatus = .failure(L("settings.backup.invalidFile"))
            return
        }

        do {
            try AppBackupService.restore(
                document,
                userDefaults: .standard,
                rightClickStore: LocalRightClickConfigStore()
            )
            RightClickConfigStore.broadcast(document.rightClick)
            SmoothScrollEngine.shared.reload()
            backupStatus = .success(L("settings.backup.importSuccess"))
        } catch {
            backupStatus = .failure(L("settings.backup.writeFailed"))
        }
    }

    private var backupContentType: UTType {
        UTType(filenameExtension: "menutoolsbackup") ?? .data
    }
}
