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
                        if isCheckingUpdate {
                            ProgressView()
                                .controlSize(.small)
                        } else if let update = availableUpdate {
                            Button(L("settings.download", update.version)) {
                                UpdateCheckerService.openDownloadPage(update)
                            }
                        } else {
                            Button(L("settings.checkNow")) {
                                checkForUpdate()
                            }
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

    private func exportBackup() {
        guard !isBackupOperationInProgress else { return }
        isBackupOperationInProgress = true
        defer { isBackupOperationInProgress = false }

        let panel = NSSavePanel()
        panel.title = L("settings.backup.export")
        panel.allowedContentTypes = [backupContentType]
        panel.nameFieldStringValue = L("settings.backup.defaultFilename")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let document = AppBackupService.makeDocument(
                userDefaults: .standard,
                rightClick: RightClickConfigStore.load(),
                appVersion: "1.0.1",
                createdAt: Date()
            )
            let data = try AppBackupService.encode(document, encoder: JSONEncoder())
            try LocalAppBackupFileAccess().write(data, to: url)
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
            let data = try LocalAppBackupFileAccess().read(from: url)
            document = try AppBackupService.decode(data, decoder: JSONDecoder())
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
