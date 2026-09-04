import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口统一尺寸（各 Tab 一致，避免切换时窗口重置闪烁）
enum SettingsLayout {
    /// 右侧详情区宽度；各功能设置页继续复用此值。
    static let width: CGFloat = 600
    static let height: CGFloat = 568
    static let sidebarWidth: CGFloat = 190
    static let headerHeight: CGFloat = 52
    static let windowWidth: CGFloat = 820
    static let windowHeight: CGFloat = 620
}

/// 设置窗口宽度固定，侧边栏作为一级导航始终保留，不提供折叠入口。
enum SettingsSidebarPolicy {
    static let allowsCollapsing = false
}

/// 侧边栏视觉策略：不再使用 List 的不透明系统底板，仅让当前选中项呈现 Liquid Glass。
enum SettingsSidebarVisualPolicy {
    static let usesSystemListBackground = false
    static let usesGlassSelection = true
    /// 导航位置只由选中态表达，避免键盘焦点环造成“双选中”错觉。
    static let showsSystemFocusRing = false
    static let selectionTintOpacity = 0.28
    static let containerSpacing: CGFloat = 8

    static func itemStyle(isSelected: Bool, isHovered: Bool) -> SettingsSidebarItemStyle {
        if isSelected {
            return SettingsSidebarItemStyle(
                showsGlass: true,
                tintOpacity: selectionTintOpacity,
                backgroundOpacity: 0
            )
        }

        return SettingsSidebarItemStyle(
            showsGlass: false,
            tintOpacity: 0,
            backgroundOpacity: isHovered ? 0.07 : 0
        )
    }
}

struct SettingsSidebarItemStyle: Equatable, Sendable {
    let showsGlass: Bool
    let tintOpacity: Double
    let backgroundOpacity: Double
}

enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
    case general
    case plugins
    case networkTraffic
    case volume
    case rightClick
    case scroll
    case windowManagement
    case appLaunch
    case screenshot
    case clipboard

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .general: return "settings.tab.general"
        case .plugins: return "settings.tab.plugins"
        case .networkTraffic: return "traffic.title"
        case .volume: return "settings.tab.volume"
        case .rightClick: return "settings.tab.rightClick"
        case .scroll: return "settings.tab.scroll"
        case .windowManagement: return "settings.tab.windowManagement"
        case .appLaunch: return "settings.tab.appLaunch"
        case .screenshot: return "settings.tab.screenshot"
        case .clipboard: return "settings.tab.clipboard"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .plugins: return "puzzlepiece.extension"
        case .networkTraffic: return "arrow.up.arrow.down.circle"
        case .volume: return "speaker.wave.2.bubble"
        case .rightClick: return "contextualmenu.and.cursorarrow"
        case .scroll: return "computermouse"
        case .windowManagement: return "macwindow.on.rectangle"
        case .appLaunch: return "app.badge"
        case .screenshot: return "camera.viewfinder"
        case .clipboard: return "clipboard"
        }
    }

    var pluginID: BuiltInPluginID? {
        switch self {
        case .general, .plugins: return nil
        case .networkTraffic: return .networkTraffic
        case .volume: return .appVolume
        case .rightClick: return .finderTools
        case .scroll: return .smoothScroll
        case .windowManagement: return .windowManagement
        case .appLaunch: return .appLauncher
        case .screenshot: return .screenshot
        case .clipboard: return .clipboard
        }
    }

    static let primaryTabs: [SettingsTab] = [.general, .plugins]

    static func enabledFeatureTabs(
        enabledPluginIDs: Set<BuiltInPluginID>
    ) -> [SettingsTab] {
        allCases.filter { tab in
            guard let pluginID = tab.pluginID else { return false }
            return enabledPluginIDs.contains(pluginID)
        }
    }

    static func visibleTabs(enabledPluginIDs: Set<BuiltInPluginID>) -> [SettingsTab] {
        primaryTabs + enabledFeatureTabs(enabledPluginIDs: enabledPluginIDs)
    }

    static func fallback(
        for tab: SettingsTab,
        enabledPluginIDs: Set<BuiltInPluginID>
    ) -> SettingsTab {
        visibleTabs(enabledPluginIDs: enabledPluginIDs).contains(tab) ? tab : .plugins
    }
}

/// 设置窗口（⌘, / 面板齿轮按钮打开）：左侧导航，右侧显示当前功能详情。
struct SettingsView: View {
    @AppStorage(SettingsKey.appLanguage) private var appLanguage = AppLanguage.system.rawValue
    @State private var selectedTab: SettingsTab?
    @State private var pluginManager = BuiltInPluginManager.shared
    @Namespace private var sidebarGlassNamespace

    init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: currentTab.symbol)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(L(currentTab.titleKey))
                        .font(.title3.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: SettingsLayout.headerHeight)

                Divider()

                selectedDetail
                    .frame(width: SettingsLayout.width, height: SettingsLayout.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: SettingsLayout.windowWidth, height: SettingsLayout.windowHeight)
        .id(appLanguage)   // 切换语言时整体重建，连侧边栏标签一起刷新
        .onAppear {
            selectedTab = SettingsTab.fallback(
                for: currentTab,
                enabledPluginIDs: pluginManager.enabledPluginIDs
            )
        }
        .onChange(of: pluginManager.enabledPluginIDs) { _, enabledPluginIDs in
            selectedTab = SettingsTab.fallback(
                for: currentTab,
                enabledPluginIDs: enabledPluginIDs
            )
        }
    }

    private var currentTab: SettingsTab {
        selectedTab ?? .general
    }

    private var settingsSidebar: some View {
        GlassEffectContainer(spacing: SettingsSidebarVisualPolicy.containerSpacing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    sidebarSection(
                        title: L("settings.sidebar.settings"),
                        tabs: SettingsTab.primaryTabs
                    )

                    let featureTabs = SettingsTab.enabledFeatureTabs(
                        enabledPluginIDs: pluginManager.enabledPluginIDs
                    )
                    if !featureTabs.isEmpty {
                        sidebarSection(
                            title: L("settings.sidebar.enabledFeatures"),
                            tabs: featureTabs
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.never)
        }
        .frame(width: SettingsLayout.sidebarWidth)
        .background(SettingsSidebarBackdrop())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.separator.opacity(0.42))
                .frame(width: 0.5)
        }
    }

    private func sidebarSection(title: String, tabs: [SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)

            VStack(spacing: 4) {
                ForEach(tabs) { tab in
                    SettingsSidebarNavigationItem(
                        tab: tab,
                        title: L(tab.titleKey),
                        isSelected: currentTab == tab,
                        glassNamespace: sidebarGlassNamespace
                    ) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            selectedTab = tab
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        switch currentTab {
        case .general:
            GeneralSettingsView()
        case .plugins:
            PluginCenterView(manager: pluginManager) { tab in
                selectedTab = tab
            }
        case .networkTraffic:
            NetworkTrafficSettingsView()
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
        case .clipboard:
            ClipboardHistorySettingsView()
        }
    }
}

private struct SettingsSidebarBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .light ? 0.34 : 0.035),
                    Color.accentColor.opacity(colorScheme == .light ? 0.025 : 0.045),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct SettingsSidebarNavigationItem: View {
    let tab: SettingsTab
    let title: String
    let isSelected: Bool
    let glassNamespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let style = SettingsSidebarVisualPolicy.itemStyle(
            isSelected: isSelected,
            isHovered: isHovered
        )

        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))

                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(!SettingsSidebarVisualPolicy.showsSystemFocusRing)
        .modifier(
            SettingsSidebarItemSurface(
                style: style,
                glassNamespace: glassNamespace
            )
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsSidebarItemSurface: ViewModifier {
    let style: SettingsSidebarItemStyle
    let glassNamespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if style.showsGlass {
            content
                .glassEffect(
                    .regular
                        .tint(Color.accentColor.opacity(style.tintOpacity))
                        .interactive(),
                    in: .rect(cornerRadius: 10)
                )
                .glassEffectID("settings.sidebar.selection", in: glassNamespace)
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(style.backgroundOpacity))
                }
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
