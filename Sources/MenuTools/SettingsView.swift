import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口统一尺寸（各 Tab 一致，避免切换时窗口重置闪烁）
enum SettingsLayout {
    static let width: CGFloat = 600
    static let height: CGFloat = 580
    static let tabBarHeight: CGFloat = 44
    static let windowHeight: CGFloat = height + tabBarHeight
}

enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
    case general
    case plugins
    case volume
    case rightClick
    case scroll
    case windowManagement
    case appLaunch
    case screenshot

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .general: return "settings.tab.general"
        case .plugins: return "settings.tab.plugins"
        case .volume: return "settings.tab.volume"
        case .rightClick: return "settings.tab.rightClick"
        case .scroll: return "settings.tab.scroll"
        case .windowManagement: return "settings.tab.windowManagement"
        case .appLaunch: return "settings.tab.appLaunch"
        case .screenshot: return "settings.tab.screenshot"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .plugins: return "puzzlepiece.extension"
        case .volume: return "speaker.wave.2.bubble"
        case .rightClick: return "contextualmenu.and.cursorarrow"
        case .scroll: return "computermouse"
        case .windowManagement: return "macwindow.on.rectangle"
        case .appLaunch: return "app.badge"
        case .screenshot: return "camera.viewfinder"
        }
    }

    var pluginID: BuiltInPluginID? {
        switch self {
        case .general, .plugins: return nil
        case .volume: return .appVolume
        case .rightClick: return .finderTools
        case .scroll: return .smoothScroll
        case .windowManagement: return .windowManagement
        case .appLaunch: return .appLauncher
        case .screenshot: return .screenshot
        }
    }

    static func visibleTabs(enabledPluginIDs: Set<BuiltInPluginID>) -> [SettingsTab] {
        allCases.filter { tab in
            guard let pluginID = tab.pluginID else { return true }
            return enabledPluginIDs.contains(pluginID)
        }
    }

    static func fallback(
        for tab: SettingsTab,
        enabledPluginIDs: Set<BuiltInPluginID>
    ) -> SettingsTab {
        visibleTabs(enabledPluginIDs: enabledPluginIDs).contains(tab) ? tab : .plugins
    }
}

/// 设置窗口（⌘, / 面板齿轮按钮打开）：分标签容纳通用与右键工具
struct SettingsView: View {
    @AppStorage(SettingsKey.appLanguage) private var appLanguage = AppLanguage.system.rawValue
    @State private var selectedTab: SettingsTab
    @State private var pluginManager = BuiltInPluginManager.shared

    init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        let visibleTabs = SettingsTab.visibleTabs(enabledPluginIDs: pluginManager.enabledPluginIDs)
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(visibleTabs) { tab in
                    Label(L(tab.titleKey), systemImage: tab.symbol)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityLabel(L("settings.title"))

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView()
                case .plugins:
                    PluginCenterView(manager: pluginManager)
                case .volume:
                    AppVolumeSettingsView()
                case .rightClick:
                    RightClickToolsView()
                case .scroll:
                    ScrollSettingsView()
                case .windowManagement:
                    WindowManagementSettingsView()
                case .appLaunch:
                    AppLaunchSettingsView()
                case .screenshot:
                    ScreenshotSettingsView()
                }
            }
            .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.windowHeight)
        .id(appLanguage)   // 切换语言时整体重建，连 Tab 标签一起刷新
        .onAppear {
            selectedTab = SettingsTab.fallback(
                for: selectedTab,
                enabledPluginIDs: pluginManager.enabledPluginIDs
            )
        }
        .onChange(of: pluginManager.enabledPluginIDs) { _, enabledPluginIDs in
            selectedTab = SettingsTab.fallback(
                for: selectedTab,
                enabledPluginIDs: enabledPluginIDs
            )
        }
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
                .onChange(of: autoCheckUpdate) { _, enabled in
                    SparkleUpdateService.shared.setAutomaticChecksEnabled(enabled)
                }

                LabeledContent(L("settings.currentVersion"), value: "v\(AppVersionService.current)")

                LabeledContent {
                    Button(L("settings.checkNow")) {
                        checkForUpdate()
                    }
                    .disabled(!SparkleUpdateService.shared.canCheckForUpdates)
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
        SparkleUpdateService.shared.checkForUpdates()
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
            AppVersionService.current
        )

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try AppBackupService.export(
                to: url,
                userDefaults: .standard,
                rightClick: RightClickConfigStore.load(),
                appVersion: AppVersionService.current,
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
