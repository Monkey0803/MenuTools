import AppKit
import SwiftUI

/// 系统开关的当前状态快照
struct SystemToggleStates {
    var hiddenFilesShown = false
    var muted = false
    var dockHidden = false
    var menuBarHidden = false
    var nightShift = false
}

/// 入场动画只用于建立层次，不应让底部内容等待接近一秒才出现。
enum MenuPanelEntranceTiming {
    static func delay(for index: Int) -> Double {
        Double(min(max(index, 0), 5)) * 0.03
    }
}

/// 卡片错峰入场动画
private struct Entrance: ViewModifier {
    let appeared: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(
                .spring(response: 0.38, dampingFraction: 0.82)
                    .delay(MenuPanelEntranceTiming.delay(for: index)),
                value: appeared
            )
    }
}

private extension View {
    func entrance(_ index: Int, appeared: Bool) -> some View {
        modifier(Entrance(appeared: appeared, index: index))
    }

    func controlCenterCircleSurface(
        tint: Color = .blue,
        selected: Bool = false,
        interactive: Bool = false
    ) -> some View {
        modifier(
            ControlCenterCircleSurface(
                tint: tint,
                selected: selected,
                interactive: interactive
            )
        )
    }
}

extension View {
    /// 仿控制中心的深色半透明表面：比系统默认 Liquid Glass 更克制，边缘更清晰。
    func controlCenterSurface(
        tint: Color? = nil,
        selected: Bool = false,
        interactive: Bool = false,
        shape: AnyShape = AnyShape(.rect(cornerRadius: 16))
    ) -> some View {
        modifier(
            ControlCenterSurface(
                tint: tint,
                selected: selected,
                interactive: interactive,
                shape: shape
            )
        )
    }

    /// 给没有完整卡片表面的图标按钮提供轻量悬停反馈。
    func controlCenterHover(
        shape: AnyShape = AnyShape(.rect(cornerRadius: 8))
    ) -> some View {
        modifier(ControlCenterHover(shape: shape))
    }
}

struct ControlCenterSurface: ViewModifier {
    let tint: Color?
    let selected: Bool
    let interactive: Bool
    let shape: AnyShape
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let accent = tint ?? .blue
        let base = Color(nsColor: .controlBackgroundColor)
        let highlighted = interactive && isHovered
        let style = ControlCenterSurfaceStyle.resolve(selected: selected, highlighted: highlighted)
        let fill = selected
            ? AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.38),
                        accent.opacity(0.92),
                        accent.opacity(0.64),
                        base.opacity(0.84)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            : AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.white.opacity(highlighted ? 0.15 : 0.075),
                        base.opacity(0.88),
                        Color.black.opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

        return content
            .background {
                ZStack {
                    shape.fill(fill)
                    if selected {
                        // 顶部镜面反射和底部暗部必须分层绘制，单一 tint 渐变仍会显得像平面色块。
                        shape.fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(style.specularOpacity),
                                    Color.white.opacity(style.specularOpacity * 0.16),
                                    .clear
                                ],
                                center: UnitPoint(x: 0.32, y: 0.02),
                                startRadius: 0,
                                endRadius: 48
                            )
                        )
                        .blendMode(.screen)
                        shape.fill(
                            LinearGradient(
                                colors: [.clear, .clear, Color.black.opacity(style.lowerRimOpacity)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.multiply)
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                ZStack {
                    shape.stroke(
                        LinearGradient(
                            colors: selected
                                ? [Color.white.opacity(0.92), accent.opacity(0.86), Color.black.opacity(0.48)]
                                : highlighted
                                    ? [Color.white.opacity(0.58), Color.white.opacity(0.18)]
                                    : [Color.white.opacity(0.28), Color.white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: selected ? 1.35 : (highlighted ? 0.9 : 0.6)
                    )
                    if selected {
                        shape.stroke(Color.white.opacity(0.72), lineWidth: 1)
                            .mask(
                                LinearGradient(
                                    colors: [.white, .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    }
                }
            }
            .shadow(
                color: selected
                    ? Color.black.opacity(0.48)
                    : (highlighted ? Color.black.opacity(0.38) : Color.black.opacity(0.28)),
                radius: style.shadowRadius,
                y: style.shadowY
            )
            .shadow(color: selected ? accent.opacity(0.34) : .clear, radius: 5, y: 1)
            .animation(.easeOut(duration: 0.16), value: highlighted)
            .onHover { hovering in
                guard interactive else { return }
                isHovered = hovering
            }
    }
}

/// 可自动测试的表面层次参数；渲染层据此区分平面悬停与凸起选中态。
struct ControlCenterSurfaceStyle: Equatable, Sendable {
    let specularOpacity: Double
    let lowerRimOpacity: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    static func resolve(selected: Bool, highlighted: Bool) -> Self {
        if selected {
            return Self(specularOpacity: 0.58, lowerRimOpacity: 0.34, shadowRadius: 10, shadowY: 5)
        }
        if highlighted {
            return Self(specularOpacity: 0.16, lowerRimOpacity: 0.14, shadowRadius: 7, shadowY: 3)
        }
        return Self(specularOpacity: 0.08, lowerRimOpacity: 0.08, shadowRadius: 5, shadowY: 2)
    }
}

private struct ControlCenterCircleSurface: ViewModifier {
    let tint: Color
    let selected: Bool
    let interactive: Bool

    func body(content: Content) -> some View {
        return content
            .frame(width: 40, height: 40)
            .modifier(
                ControlCenterSurface(
                    tint: tint,
                    selected: selected,
                    interactive: interactive,
                    shape: AnyShape(Circle())
                )
            )
    }
}

struct ControlCenterHover: ViewModifier {
    let shape: AnyShape
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Color.white.opacity(isHovered ? 0.11 : 0)))
            .clipShape(shape)
            .overlay {
                shape.stroke(Color.white.opacity(isHovered ? 0.24 : 0), lineWidth: 0.6)
            }
            .shadow(color: Color.black.opacity(isHovered ? 0.2 : 0), radius: 4, y: 2)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

enum TranslationPanelEntryPolicy {
    static func shouldShow(isPluginEnabled: Bool) -> Bool {
        isPluginEnabled
    }
}

/// 菜单栏弹出的主面板：控制中心风格，自动适配深色 / 浅色
struct MenuPanelView: View {
    private let openSettingsAction: ((SettingsTab) -> Void)?
    @AppStorage(SettingsKey.menuBarIcon) private var menuBarIcon = MenuBarIcon.default.rawValue
    @AppStorage(SettingsKey.togglesShowTitle) private var togglesShowTitle = false
    @AppStorage(SettingsKey.preferredTerminal) private var preferredTerminal = TerminalApp.systemDefault.rawValue
    @AppStorage(SettingsKey.appLanguage) private var appLanguage = AppLanguage.system.rawValue
    @Environment(\.openSettings) private var openSettings

    @ObservedObject private var caffeinate = CaffeinateService.shared
    @ObservedObject private var bleMonitor = BLEBatteryMonitor.shared
    @State private var isDarkMode = AppearanceService.isDarkMode
    @State private var btDevices: [BluetoothDeviceBattery] = []
    @State private var toggles = SystemToggleStates()
    @State private var derivedDataSize: Int64?
    @State private var isCleaningDerivedData = false
    @State private var systemResourceService = SystemResourceService()
    @State private var networkService = NetworkStatusService.shared
    @State private var batteryHealthService = BatteryHealthService()
    @State private var displayService = DisplayService()
    @State private var storageAnalysisService = StorageAnalysisService()
    @State private var storageCategoryToConfirm: StorageCategory?
    @State private var quickActionService = QuickActionService()
    @State private var screenshotService = ScreenshotService.shared
    @State private var activeQuickAction: QuickAction?
    @State private var appLauncherService = AppLauncherService.shared
    @State private var sceneService = SceneService.shared
    @State private var focusModeService = FocusModeService.shared
    @State private var globalShortcutService = GlobalShortcutService.shared
    @State private var appVolumeService = AppVolumeService.shared
    @State private var networkTrafficService = NetworkTrafficService.shared
    @State private var pluginManager = BuiltInPluginManager.shared
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var appeared = false
    @State private var tooltipWidth: CGFloat = 0

    init(openSettingsAction: ((SettingsTab) -> Void)? = nil) {
        self.openSettingsAction = openSettingsAction
    }

    private let themeChanged = DistributedNotificationCenter.default().publisher(
        for: Notification.Name("AppleInterfaceThemeChangedNotification")
    )

    private var enabledQuickActions: [QuickAction] {
        QuickAction.allCases.filter { action in
            switch action {
            case .screenshot:
                return pluginManager.isEnabled(.screenshot)
            case .emptyTrash, .restartFinder:
                return pluginManager.isEnabled(.finderTools)
            case .lockScreen, .flushDNS, .openSystemSettings:
                return pluginManager.isEnabled(.systemControls)
            }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            header
                .entrance(0, appeared: appeared)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    if pluginManager.isEnabled(.systemControls)
                        || pluginManager.isEnabled(.finderTools) {
                        heroTiles
                            .entrance(1, appeared: appeared)
                    }
                    if TranslationPanelEntryPolicy.shouldShow(
                        isPluginEnabled: pluginManager.isEnabled(.translation)
                    ) {
                        translationCard
                            .entrance(2, appeared: appeared)
                    }
                    if !enabledQuickActions.isEmpty {
                        quickActionsCard
                            .entrance(2, appeared: appeared)
                    }
                    if pluginManager.isEnabled(.automation) {
                        ScenePresetsCard(activeScene: sceneService.activeScene, apply: applyScene)
                            .entrance(3, appeared: appeared)
                        GlobalShortcutCard(service: globalShortcutService, report: flashStatus)
                            .entrance(4, appeared: appeared)
                        FocusModeCard(
                            isEnabled: focusModeService.isEnabled,
                            isDoNotDisturbEnabled: focusModeService.isDoNotDisturbEnabled,
                            isBusy: focusModeService.isBusy,
                            toggle: toggleFocusMode,
                            toggleDoNotDisturb: toggleDoNotDisturb,
                            openSettings: openFocusSettings
                        )
                        .entrance(5, appeared: appeared)
                    }
                    if pluginManager.isEnabled(.systemInsights) {
                        systemResourceCard
                            .entrance(6, appeared: appeared)
                        networkCard
                            .entrance(7, appeared: appeared)
                        batteryHealthCard
                            .entrance(8, appeared: appeared)
                        displayCard
                            .entrance(9, appeared: appeared)
                        storageCard
                            .entrance(10, appeared: appeared)
                    }
                    if pluginManager.isEnabled(.networkTraffic) {
                        networkTrafficCard
                            .entrance(11, appeared: appeared)
                    }
                    if pluginManager.isEnabled(.systemControls) {
                        quickToggles
                            .entrance(11, appeared: appeared)
                    }
                    if pluginManager.isEnabled(.appVolume) {
                        AppVolumeCard(service: appVolumeService) {
                            openSettingsAction?(.volume)
                        }
                        .entrance(12, appeared: appeared)
                    }
                    if pluginManager.isEnabled(.systemInsights) {
                        bluetoothCard
                            .entrance(13, appeared: appeared)
                    }
                    if pluginManager.isEnabled(.systemInsights) {
                        cleanupTiles
                            .entrance(14, appeared: appeared)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.clear)

            footer
                .entrance(15, appeared: appeared)
        }
        .padding(16)
        // 菜单栏窗口必须有明确高度，否则 ScrollView 会按全部卡片的理想高度展开，
        // 在菜单栏屏幕上无法正常显示弹出面板。
        .frame(width: 320, height: 640)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.82))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.34)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7)
        }
        .overlay(alignment: .bottom) {
            if let statusMessage {
                statusBanner(statusMessage)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                    .allowsHitTesting(false)
            }
        }
        .overlayPreferenceValue(ToggleTooltipKey.self) { tip in
            GeometryReader { proxy in
                if let tip {
                    let rect = proxy[tip.anchor]
                    let margin: CGFloat = 6
                    let halfW = tooltipWidth / 2
                    let clampedX = min(max(rect.midX, halfW + margin), proxy.size.width - halfW - margin)
                    Text(tip.text)
                        .font(.caption2)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .controlCenterSurface(shape: AnyShape(.capsule))
                        .background {
                            GeometryReader { g in
                                Color.clear
                                    .onAppear { tooltipWidth = g.size.width }
                                    .onChange(of: g.size.width) { _, w in tooltipWidth = w }
                            }
                        }
                        .position(x: clampedX, y: rect.minY - 16)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                        .allowsHitTesting(false)
                }
            }
        }
        .id(appLanguage)   // 切换语言时重建面板，文案即时生效
        .onAppear {
            appeared = true
        }
        .onReceive(themeChanged) { _ in
            // 系统外观变化时同步开关状态
            DispatchQueue.main.async {
                withAnimation(.smooth(duration: 0.3)) {
                    isDarkMode = AppearanceService.isDarkMode
                }
            }
        }
        .task {
            if pluginManager.isEnabled(.systemControls) {
                refreshToggles()
            }
            if pluginManager.isEnabled(.systemInsights) {
                refreshDerivedDataSize()
            }
            if pluginManager.isEnabled(.appLauncher) || pluginManager.isEnabled(.automation) {
                appLauncherService.refresh()
            }
            guard pluginManager.isEnabled(.systemInsights) else { return }
            bleMonitor.start()
            // 不在面板打开瞬间读取 Focus：读取会点击 Control Center，可能抢走菜单弹层焦点。
            // 状态在用户执行切换后刷新；未读取前由卡片显示“状态由系统控制”。
            // 面板展示期间每 30 秒刷新一次蓝牙设备电量
            while !Task.isCancelled {
                bleMonitor.refresh()
                let devices = await BluetoothBatteryService.fetch()
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.3)) {
                    btDevices = devices
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task {
            guard pluginManager.isEnabled(.systemInsights) else { return }
            while !Task.isCancelled {
                systemResourceService.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task {
            guard pluginManager.isEnabled(.systemInsights) else { return }
            networkService.refresh()
            batteryHealthService.refresh()
            displayService.refresh()
            storageAnalysisService.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                networkService.refresh()
                batteryHealthService.refresh()
                displayService.refresh()
                storageAnalysisService.refresh()
            }
        }
        .task {
            guard pluginManager.isEnabled(.networkTraffic) else { return }
            networkTrafficService.beginLiveView()
            defer { networkTrafficService.endLiveView() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .alert(L("storage.confirm.title"), isPresented: Binding(
            get: { storageCategoryToConfirm != nil },
            set: { if !$0 { storageCategoryToConfirm = nil } }
        )) {
            Button(L("storage.clean"), role: .destructive) {
                if let category = storageCategoryToConfirm {
                    storageCategoryToConfirm = nil
                    cleanStorage(category)
                }
            }
            Button(L("update.cancel"), role: .cancel) {
                storageCategoryToConfirm = nil
            }
        } message: {
            Text(L("storage.confirm.message"))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: menuBarIcon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(
                        LinearGradient(colors: [.blue, .purple],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                )
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 1) {
                Text("MenuTools")
                    .font(.headline)
                Text(L("panel.subtitle"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(.secondary)
                        .controlCenterSurface(interactive: true, shape: AnyShape(Circle()))
            .help(L("footer.quit"))
            Button {
                if let openSettingsAction {
                    openSettingsAction(.general)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(.secondary)
            .controlCenterSurface(interactive: true, shape: AnyShape(Circle()))
            .help(L("help.settings"))
        }
    }

    // MARK: - 主操作磁贴：终端 / 外观

    private var heroTiles: some View {
        HStack(spacing: 12) {
            if pluginManager.isEnabled(.finderTools) {
                Button(action: openFinderPathInTerminal) {
                    heroTileLabel(
                        symbol: "terminal.fill",
                        title: L("panel.tile.terminal"),
                        subtitle: currentTerminal.shortName
                    )
                }
                .buttonStyle(.plain)
                .controlCenterSurface(tint: .blue, interactive: true, shape: AnyShape(.rect(cornerRadius: 18)))
            }

            if pluginManager.isEnabled(.systemControls) {
                Button {
                    setSystemAppearance(dark: !isDarkMode)
                } label: {
                    heroTileLabel(
                        symbol: isDarkMode ? "moon.stars.fill" : "sun.max.fill",
                        title: isDarkMode ? L("panel.tile.dark") : L("panel.tile.light"),
                        subtitle: L("panel.tile.tap")
                    )
                }
                .buttonStyle(.plain)
                .controlCenterSurface(
                    tint: isDarkMode ? .indigo : .orange,
                    interactive: true,
                    shape: AnyShape(.rect(cornerRadius: 18))
                )
            }
        }
    }

    private func heroTileLabel(symbol: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect(cornerRadius: 18))
    }

    private var translationCard: some View {
        HStack(spacing: 8) {
            Button(action: TranslationWindowController.shared.showFromClipboard) {
                HStack(spacing: 12) {
                    Image(systemName: "character.bubble")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                        .background(.tint.opacity(0.14), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("translation.windowTitle"))
                            .font(.callout.weight(.semibold))
                        Text(L("translation.panelDescription"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("translation.openWindow"))

            Button(action: openTranslationSettings) {
                Image(systemName: "gearshape")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help(L("settings.tab.translation"))
        }
        .padding(12)
        .controlCenterSurface(tint: .indigo, interactive: true, shape: AnyShape(.rect(cornerRadius: 16)))
    }

    private func openTranslationSettings() {
        if let openSettingsAction {
            openSettingsAction(.translation)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }

    // MARK: - 快捷操作中心

    private var quickActionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(L("quickAction.title"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(L("quickAction.subtitle"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                spacing: 8
            ) {
                ForEach(enabledQuickActions) { action in
                    Button {
                        performQuickAction(action)
                    } label: {
                        HStack(spacing: 7) {
                            if activeQuickAction == action {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: action.symbol)
                                    .font(.caption.weight(.semibold))
                                    .symbolRenderingMode(.hierarchical)
                            }
                            Text(L(action.titleKey))
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .controlCenterSurface(interactive: true, shape: AnyShape(.rect(cornerRadius: 12)))
                    .disabled(activeQuickAction != nil)
                    .accessibilityLabel(L(action.titleKey))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCenterSurface(tint: .blue)
    }

    // MARK: - 系统资源

    private var systemResourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(L("resource.title"))
                    .font(.caption.weight(.semibold))
                Spacer()
                if let snapshot = systemResourceService.snapshot {
                    HStack(spacing: 8) {
                        Text(memoryPressureLabel(snapshot.memoryPressure))
                            .font(.caption2)
                            .foregroundStyle(memoryPressureColor(snapshot.memoryPressure))
                        if snapshot.memoryPressure.shouldOfferMemoryRelease {
                            Button {
                                guard let result = systemResourceService.releaseMemory() else { return }
                                flashStatus(
                                    result.systemCachePurged
                                        ? L("status.memoryReleased")
                                        : L("status.memoryReleaseFailed"),
                                    isError: !result.systemCachePurged
                                )
                            } label: {
                                Label(
                                    systemResourceService.isReleasingMemory
                                        ? L("resource.releasingMemory")
                                        : L("resource.releaseMemory"),
                                    systemImage: "arrow.down.circle"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .tint(.red)
                            .disabled(systemResourceService.isReleasingMemory)
                            .help(L("resource.releaseMemory"))
                        }
                    }
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if let snapshot = systemResourceService.snapshot {
                HStack(spacing: 12) {
                    resourceMetric(
                        symbol: "cpu",
                        title: L("resource.cpu"),
                        value: "\(Int((snapshot.cpuUsage * 100).rounded()))%"
                    )
                    resourceMetric(
                        symbol: "memorychip",
                        title: L("resource.memory"),
                        value: "\(resourceBytes(snapshot.memoryUsedBytes)) / \(resourceBytes(snapshot.memoryTotalBytes))"
                    )
                }
                HStack(spacing: 12) {
                    resourceMetric(
                        symbol: "internaldrive",
                        title: L("resource.disk"),
                        value: "\(resourceBytes(snapshot.diskAvailableBytes)) \(L("resource.free"))"
                    )
                    resourceMetric(
                        symbol: "arrow.up.arrow.down",
                        title: L("resource.network"),
                        value: "↓\(resourceRate(snapshot.networkDownloadBytesPerSecond))  ↑\(resourceRate(snapshot.networkUploadBytesPerSecond))"
                    )
                }
            } else {
                Text(L("resource.loading"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCenterSurface(tint: .purple)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("resource.title"))
    }

    // MARK: - 网络状态

    private var networkCard: some View {
        let snapshot = networkService.snapshot
        return VStack(alignment: .leading, spacing: 9) {
            infoCardHeader(symbol: "wifi", title: L("network.title")) {
                Button {
                    networkService.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .controlCenterHover(shape: AnyShape(.circle))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("network.refresh"))
            }

            HStack(spacing: 12) {
                infoMetric(
                    symbol: snapshot.isConnected ? "checkmark.circle.fill" : "wifi.slash",
                    title: L("network.connection"),
                    value: networkConnectionName(snapshot),
                    color: snapshot.isConnected ? .green : .secondary
                )
                infoMetric(
                    symbol: "network",
                    title: L("network.localIP"),
                    value: snapshot.localIPv4 ?? "--"
                )
            }

            HStack(spacing: 8) {
                networkProbeButton(
                    title: snapshot.publicIPv4 ?? L("network.publicIP"),
                    symbol: "globe",
                    isLoading: networkService.isPublicIPLoading
                ) {
                    networkService.fetchPublicIP()
                }
                networkProbeButton(
                    title: snapshot.latencyMilliseconds.map { L("network.latencyValue", $0) } ?? L("network.testLatency"),
                    symbol: "speedometer",
                    isLoading: networkService.isLatencyTesting
                ) {
                    networkService.testLatency()
                }
                Text(snapshot.vpnConnected ? L("network.vpnOn") : L("network.vpnOff"))
                    .font(.caption2)
                    .foregroundStyle(snapshot.vpnConnected ? .green : .secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCenterSurface(tint: .cyan)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("network.title"))
    }

    private var networkTrafficCard: some View {
        let snapshot = networkTrafficService.snapshot
        let apps = Array(snapshot.apps.filter { !$0.isHistoricalOnly }.prefix(3))
        return VStack(alignment: .leading, spacing: 9) {
            infoCardHeader(symbol: "arrow.up.arrow.down.circle", title: L("traffic.title")) {
                Button {
                    openNetworkTrafficSettings()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .controlCenterHover(shape: AnyShape(.circle))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("traffic.viewAll"))
            }

            if apps.isEmpty {
                Text(snapshot.isAvailable ? L("traffic.noApps") : L("traffic.unavailable"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(apps) { app in
                    HStack(spacing: 8) {
                        Text(app.appName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("↓ \(resourceRate(app.downloadBytesPerSecond))  ↑ \(resourceRate(app.uploadBytesPerSecond))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                Button(L("traffic.viewAll")) {
                    openNetworkTrafficSettings()
                }
                .font(.caption2.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCenterSurface(tint: .teal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("traffic.title"))
    }

    private func openNetworkTrafficSettings() {
        if let openSettingsAction {
            openSettingsAction(.networkTraffic)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }

    private func networkConnectionName(_ snapshot: NetworkStatusSnapshot) -> String {
        if let wifiName = snapshot.wifiName, !wifiName.isEmpty { return wifiName }
        if let interfaceName = snapshot.interfaceName, snapshot.isConnected { return interfaceName }
        return L("network.offline")
    }

    private func networkProbeButton(
        title: String,
        symbol: String,
        isLoading: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .controlCenterHover()
        .foregroundStyle(.tint)
        .disabled(isLoading)
    }

    // MARK: - 电池健康

    private var batteryHealthCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            infoCardHeader(symbol: "battery.100percent", title: L("batteryHealth.title")) {
                Button {
                    batteryHealthService.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .controlCenterHover(shape: AnyShape(.circle))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("batteryHealth.refresh"))
            }

            if let snapshot = batteryHealthService.snapshot {
                HStack(spacing: 12) {
                    infoMetric(
                        symbol: "heart.fill",
                        title: L("batteryHealth.health"),
                        value: snapshot.healthPercent.map { "\($0)%" } ?? "--",
                        color: batteryHealthColor(snapshot.healthPercent)
                    )
                    infoMetric(
                        symbol: "arrow.triangle.2.circlepath",
                        title: L("batteryHealth.cycles"),
                        value: snapshot.cycleCount.map(String.init) ?? "--"
                    )
                    infoMetric(
                        symbol: snapshot.isCharging ? "bolt.fill" : "battery.75percent",
                        title: L("batteryHealth.charge"),
                        value: snapshot.currentPercent.map { "\($0)%" } ?? L("batteryHealth.notCharging"),
                        color: snapshot.isCharging ? .orange : nil
                    )
                }
                if let condition = snapshot.condition {
                    Text(condition)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L("batteryHealth.unavailable"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCenterSurface(tint: .green)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("batteryHealth.title"))
    }

    private func batteryHealthColor(_ percent: Int?) -> Color {
        guard let percent else { return .secondary }
        switch percent {
        case ..<60: return .red
        case ..<80: return .orange
        default: return .green
        }
    }

    // MARK: - 显示器工具

    private var displayCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            infoCardHeader(symbol: "display.2", title: L("display.title")) {
                Button {
                    displayService.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .controlCenterHover(shape: AnyShape(.circle))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("display.refresh"))
            }

            if displayService.displays.isEmpty {
                Text(L("display.unavailable"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayService.displays) { display in
                    HStack(spacing: 8) {
                        Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                            .font(.body)
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(display.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(display.isBuiltIn ? L("display.builtIn") : L("display.external"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(display.currentMode.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer(minLength: 4)
                        Menu {
                            ForEach(display.modes) { mode in
                                Button {
                                    setDisplayMode(display, mode: mode)
                                } label: {
                                    HStack {
                                        Text(mode.label)
                                        if mode.isCurrent { Text("✓") }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.caption)
                                .frame(width: 24, height: 24)
                        }
                        .menuStyle(.borderlessButton)
                        .controlCenterHover(shape: AnyShape(.rect(cornerRadius: 7)))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L("display.changeMode"))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCenterSurface(tint: .orange)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("display.title"))
    }

    // MARK: - 存储分析

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            infoCardHeader(symbol: "internaldrive.fill", title: L("storage.title")) {
                Button {
                    storageAnalysisService.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .controlCenterHover(shape: AnyShape(.circle))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("storage.refresh"))
            }

            if let snapshot = storageAnalysisService.snapshot {
                ForEach(snapshot.entries) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.category.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(L(entry.category.titleKey))
                            .font(.caption2)
                        Spacer(minLength: 4)
                        Text(entry.exists ? formattedStorage(entry.bytes) : "--")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if entry.category.isSafeToClean && entry.bytes > 0 {
                            Button {
                                storageCategoryToConfirm = entry.category
                            } label: {
                                if storageAnalysisService.cleaningCategory == entry.category {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "trash")
                                        .font(.caption2)
                                }
                            }
                            .buttonStyle(.plain)
                            .controlCenterHover(shape: AnyShape(.circle))
                            .foregroundStyle(.secondary)
                            .disabled(storageAnalysisService.cleaningCategory != nil)
                            .accessibilityLabel(L("storage.clean"))
                        }
                    }
                }
            } else if storageAnalysisService.isLoading {
                HStack {
                    ProgressView().controlSize(.mini)
                    Text(L("storage.loading"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L("storage.unavailable"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCenterSurface(tint: .indigo)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("storage.title"))
    }

    private func formattedStorage(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func infoCardHeader(
        symbol: String,
        title: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer()
            trailing()
        }
    }

    private func infoMetric(symbol: String, title: String, value: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(color ?? .secondary)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resourceMetric(symbol: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resourceBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    private func resourceRate(_ value: Int64) -> String {
        "\(resourceBytes(value))/s"
    }

    private func memoryPressureLabel(_ pressure: SystemMemoryPressure) -> String {
        switch pressure {
        case .normal: return L("resource.memoryNormal")
        case .warning: return L("resource.memoryWarning")
        case .critical: return L("resource.memoryCritical")
        }
    }

    private func memoryPressureColor(_ pressure: SystemMemoryPressure) -> Color {
        switch pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    // MARK: - 快捷开关带：防止锁屏 / 隐藏文件 / 静音 / 程序坞 / 菜单栏 / 夜览

    private var isOutputMuted: Bool {
        appVolumeService.output.deviceID == 0
            ? toggles.muted
            : appVolumeService.output.isMuted
    }

    private var quickToggles: some View {
        Group {
            if togglesShowTitle {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                    toggleButtons
                }
            } else {
                HStack(spacing: 9) {
                    toggleButtons
                }
            }
        }
    }

    @ViewBuilder private var toggleButtons: some View {
        quickToggle(
            symbol: caffeinate.isActive ? "lock.slash.fill" : "lock.fill",
            help: L("toggle.caffeinate"),
            isOn: caffeinate.isActive,
            pulse: caffeinate.isActive
        ) {
            caffeinate.toggle()
        }
        quickToggle(
            symbol: toggles.hiddenFilesShown ? "eye.fill" : "eye.slash",
            help: L("toggle.hiddenFiles"),
            isOn: toggles.hiddenFilesShown
        ) {
            SystemToggleService.setHiddenFilesShown(!toggles.hiddenFilesShown)
            toggles.hiddenFilesShown.toggle()
        }
        quickToggle(
            symbol: isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            help: L("toggle.mute"),
            isOn: isOutputMuted
        ) {
            if appVolumeService.output.canSetMute {
                appVolumeService.setMasterMuted(!isOutputMuted)
                toggles.muted = !isOutputMuted
                return
            }
            do {
                try SystemToggleService.setMuted(!toggles.muted)
                toggles.muted.toggle()
            } catch {
                flashStatus(error.localizedDescription, isError: true)
            }
        }
        quickToggle(
            symbol: "dock.rectangle",
            help: L("toggle.dock"),
            isOn: toggles.dockHidden
        ) {
            do {
                try SystemToggleService.setDockHidden(!toggles.dockHidden)
                toggles.dockHidden.toggle()
            } catch {
                flashStatus(error.localizedDescription, isError: true)
            }
        }
        quickToggle(
            symbol: "menubar.rectangle",
            help: L("toggle.menubar"),
            isOn: toggles.menuBarHidden
        ) {
            do {
                try SystemToggleService.setMenuBarHidden(!toggles.menuBarHidden)
                toggles.menuBarHidden.toggle()
            } catch {
                flashStatus(error.localizedDescription, isError: true)
            }
        }
        quickToggle(
            symbol: toggles.nightShift ? "sun.horizon.fill" : "sun.horizon",
            help: L("toggle.nightShift"),
            isOn: toggles.nightShift
        ) {
            do {
                try NightShiftService.setEnabled(!toggles.nightShift)
                toggles.nightShift.toggle()
            } catch {
                flashStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private func quickToggle(
        symbol: String,
        help: String,
        isOn: Bool,
        pulse: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        QuickToggleButton(
            symbol: symbol,
            title: help,
            isOn: isOn,
            pulse: pulse,
            showTitle: togglesShowTitle,
            action: action
        )
    }

    // MARK: - 蓝牙设备电量

    /// 合并两个数据源：IORegistry（AirPods 类）+ CoreBluetooth GATT（BLE 键鼠等）
    private var allBtDevices: [BluetoothDeviceBattery] {
        var merged = btDevices
        let existingNames = Set(merged.map(\.name))
        merged += bleMonitor.devices.filter { !existingNames.contains($0.name) }
        return merged.sorted {
            if $0.isHeadset != $1.isHeadset { return $0.isHeadset }
            return $0.name < $1.name
        }
    }

    private var bluetoothCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if allBtDevices.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.body)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                    Text(L("bt.empty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        bleMonitor.refresh()
                        Task {
                            let devices = await BluetoothBatteryService.fetch()
                            guard !Task.isCancelled else { return }
                            withAnimation(.smooth(duration: 0.3)) {
                                btDevices = devices
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .frame(width: 22, height: 22)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .controlCenterHover(shape: AnyShape(.circle))
                    .foregroundStyle(.secondary)
                }
            } else {
                ForEach(allBtDevices) { device in
                    deviceRow(device)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCenterSurface()
    }

    private func deviceRow(_ device: BluetoothDeviceBattery) -> some View {
        HStack(spacing: 10) {
            Image(systemName: deviceSymbol(for: device))
                .font(.body)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(device.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            if device.isHeadset {
                batteryBadge(symbol: "airpod.left", percent: device.leftPercent)
                batteryBadge(symbol: "airpod.right", percent: device.rightPercent)
                batteryBadge(symbol: "airpodspro.chargingcase.wireless.fill", percent: device.casePercent)
            } else {
                Text(device.singlePercent.map { "\($0)%" } ?? "--")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(batteryColor(device.singlePercent))
            }
        }
    }

    private func deviceSymbol(for device: BluetoothDeviceBattery) -> String {
        if device.isHeadset { return "airpods.pro" }
        let name = device.name.lowercased()
        if name.contains("keyboard") || name.contains("keys") { return "keyboard.fill" }
        if name.contains("mouse") || name.contains("master") { return "magicmouse.fill" }
        if device.isAudio || name.contains("beats") || name.contains("headphone") || name.contains("buds") { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }

    private func batteryBadge(symbol: String, percent: Int?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption)
                .symbolRenderingMode(.hierarchical)
            Text(percent.map { "\($0)" } ?? "--")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(batteryColor(percent))
        }
    }

    private func batteryColor(_ percent: Int?) -> Color {
        guard let percent else { return .secondary }
        switch percent {
        case ..<20: return .red
        case ..<50: return .orange
        default: return .green
        }
    }

    // MARK: - 清理磁贴：DerivedData

    private var cleanupTiles: some View {
        HStack(spacing: 12) {
            if pluginManager.isEnabled(.systemInsights) {
                Button(action: cleanDerivedData) {
                    cleanupTileLabel(
                        symbol: "hammer.fill",
                        title: L("cleanup.derivedData"),
                        subtitle: derivedDataSubtitle,
                        showProgress: isCleaningDerivedData
                    )
                }
                .buttonStyle(.plain)
                .disabled(isCleaningDerivedData || derivedDataSize == 0)
                .controlCenterSurface(interactive: true, shape: AnyShape(.rect(cornerRadius: 16)))
            }
        }
    }

    private func cleanupTileLabel(symbol: String, title: String, subtitle: String, showProgress: Bool) -> some View {
        HStack(spacing: 8) {
            if showProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect(cornerRadius: 16))
    }

    private var derivedDataSubtitle: String {
        if isCleaningDerivedData { return L("cleanup.cleaning") }
        guard let size = derivedDataSize else { return L("cleanup.calculating") }
        return size == 0 ? L("cleanup.cleared") : XcodeCleanerService.formatted(size)
    }

    // MARK: - 状态提示 / 底部

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(statusIsError ? .orange : .green)
                .symbolEffect(.bounce, value: message)
            Text(message)
                .font(.caption)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(10)
        .controlCenterSurface(shape: AnyShape(.rect(cornerRadius: 12)))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("v\(AppVersionService.current)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button(L("footer.checkUpdate")) {
                checkForUpdate()
            }
            .buttonStyle(.plain)
            .controlCenterHover()
            .font(.caption2)
            .foregroundStyle(.secondary)
            .disabled(!SparkleUpdateService.shared.canCheckForUpdates)

            Spacer()
        }
    }

    // MARK: - Actions

    private var currentTerminal: TerminalApp {
        TerminalApp(rawValue: preferredTerminal) ?? .systemDefault
    }

    private func openFinderPathInTerminal() {
        do {
            let directory = try FinderService.frontWindowPath()
            try TerminalLauncher.open(directory: directory, in: currentTerminal)
            flashStatus(L("status.openedIn", currentTerminal.displayName, directory.path), isError: false)
        } catch {
            flashStatus(error.localizedDescription, isError: true)
        }
    }

    private func setSystemAppearance(dark: Bool) {
        do {
            try AppearanceService.setDarkMode(dark)
            withAnimation(.smooth(duration: 0.3)) {
                isDarkMode = dark
            }
        } catch {
            flashStatus(error.localizedDescription, isError: true)
        }
    }

    private func performQuickAction(_ action: QuickAction) {
        guard activeQuickAction == nil else { return }
        activeQuickAction = action

        if action == .screenshot {
            Task { @MainActor in
                do {
                    _ = try await screenshotService.captureConfigured()
                    flashStatus(L("quickAction.success", L(action.titleKey)), isError: false)
                } catch {
                    flashStatus(error.localizedDescription, isError: true)
                }
                activeQuickAction = nil
            }
            return
        }

        defer { activeQuickAction = nil }

        do {
            try quickActionService.perform(action)
            flashStatus(L("quickAction.success", L(action.titleKey)), isError: false)
        } catch {
            flashStatus(error.localizedDescription, isError: true)
        }
    }

    private func applyScene(_ scene: ScenePreset) {
        do {
            try sceneService.apply(scene, launcher: appLauncherService, focusService: focusModeService)
            flashStatus(L("scene.applied", L(scene.titleKey)), isError: false)
        } catch {
            flashStatus(error.localizedDescription, isError: true)
        }
    }

    private func toggleFocusMode() {
        do {
            try focusModeService.toggle()
            flashStatus(L("focus.toggled"), isError: false)
        } catch {
            flashStatus(error.localizedDescription, isError: true)
        }
    }

    private func toggleDoNotDisturb() {
        do {
            try focusModeService.toggleDoNotDisturb()
            flashStatus(L("focus.doNotDisturbToggled"), isError: false)
        } catch {
            flashStatus(error.localizedDescription, isError: true)
        }
    }

    private func openFocusSettings() {
        do {
            try focusModeService.openSettings()
        } catch {
            flashStatus(error.localizedDescription, isError: true)
        }
    }

    private func setDisplayMode(_ display: DisplayInfo, mode: DisplayModeInfo) {
        do {
            try displayService.setMode(displayID: display.id, mode: mode)
            flashStatus(L("display.changed", mode.label), isError: false)
        } catch {
            flashStatus(error.localizedDescription, isError: true)
        }
    }

    private func cleanStorage(_ category: StorageCategory) {
        Task {
            do {
                try await storageAnalysisService.clean(category)
                flashStatus(L("storage.cleaned", L(category.titleKey)), isError: false)
            } catch {
                flashStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private func refreshToggles() {
        toggles = SystemToggleStates(
            hiddenFilesShown: SystemToggleService.hiddenFilesShown,
            muted: SystemToggleService.isMuted,
            dockHidden: SystemToggleService.isDockHidden,
            menuBarHidden: SystemToggleService.isMenuBarHidden,
            nightShift: NightShiftService.isEnabled
        )
    }

    private func refreshDerivedDataSize() {
        Task {
            let size = await Task.detached(priority: .utility) {
                XcodeCleanerService.directorySize()
            }.value
            withAnimation(.smooth(duration: 0.3)) {
                derivedDataSize = size
            }
        }
    }

    private func cleanDerivedData() {
        guard !isCleaningDerivedData else { return }
        let sizeBefore = derivedDataSize ?? 0
        isCleaningDerivedData = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try XcodeCleanerService.clean()
                }.value
                isCleaningDerivedData = false
                withAnimation(.smooth(duration: 0.3)) {
                    derivedDataSize = 0
                }
                flashStatus(L("status.freed", XcodeCleanerService.formatted(sizeBefore)), isError: false)
            } catch {
                isCleaningDerivedData = false
                flashStatus(error.localizedDescription, isError: true)
            }
            refreshDerivedDataSize()
        }
    }

    private func checkForUpdate() {
        SparkleUpdateService.shared.checkForUpdates()
    }

    private func flashStatus(_ message: String, isError: Bool) {
        withAnimation(.smooth(duration: 0.25)) {
            statusMessage = message
            statusIsError = isError
        }
        Task {
            try? await Task.sleep(for: .seconds(isError ? 6 : 3))
            withAnimation(.smooth(duration: 0.25)) {
                if statusMessage == message {
                    statusMessage = nil
                }
            }
        }
    }
}

/// 单个快捷开关按钮：自带悬停状态，以控制中心胶囊即时展示提示（替代延迟高的系统 .help 提示）
private struct QuickToggleButton: View {
    let symbol: String
    let title: String
    let isOn: Bool
    let pulse: Bool
    let showTitle: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let icon = Image(systemName: symbol)
            .font(.body.weight(.medium))
            .symbolRenderingMode(.hierarchical)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: isOn)
            .symbolEffect(.pulse, options: .repeating, isActive: pulse)
        let button = Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { action() }
        } label: {
            if showTitle {
                VStack(spacing: 4) {
                    icon.frame(height: 22)
                    Text(title)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(.rect(cornerRadius: 12))
            } else {
                icon.contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        Group {
            if showTitle {
                button.controlCenterSurface(
                    tint: .blue,
                    selected: isOn,
                    interactive: true,
                    shape: AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                )
            } else {
                button.controlCenterCircleSurface(
                    tint: .blue,
                    selected: isOn,
                    interactive: true
                )
            }
        }
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
        .accessibilityLabel(title)
        // 仅“仅图标”模式上报悬停位置，由面板层统一渲染提示气泡（避免被容器裁剪）
        .anchorPreference(key: ToggleTooltipKey.self, value: .bounds) { anchor in
            (hovering && !showTitle) ? ToggleTooltip(text: title, anchor: anchor) : nil
        }
    }
}

/// 悬停提示的位置与文本（通过 anchor preference 从子按钮上报到面板层）
private struct ToggleTooltip: Equatable {
    let text: String
    let anchor: Anchor<CGRect>
    static func == (lhs: ToggleTooltip, rhs: ToggleTooltip) -> Bool { lhs.text == rhs.text }
}

private struct ToggleTooltipKey: PreferenceKey {
    static let defaultValue: ToggleTooltip? = nil
    static func reduce(value: inout ToggleTooltip?, nextValue: () -> ToggleTooltip?) {
        if let next = nextValue() { value = next }
    }
}

/// 剪贴板历史弹出面板。
enum ClipboardHistoryPopoverLayout {
    static let minWidth: CGFloat = 300
    static let idealWidth: CGFloat = 360
    static let maxWidth: CGFloat = 420
    static let minHeight: CGFloat = 360
    static let idealHeight: CGFloat = 420
    static let maxHeight: CGFloat = 520
}

struct ClipboardHistoryPopover: View {
    private enum FocusTarget: Hashable {
        case search
        case keyboard
    }

    let items: [ClipboardHistoryItem]
    let onCopy: (ClipboardHistoryItem) -> Void
    let onPerformAction: (ClipboardHistoryItem, ClipboardHistoryAction) -> Void
    let onTogglePinned: (UUID) -> Void
    let onRemove: (UUID) -> Void
    let onClearHistory: () -> Void
    let onClearClipboard: () -> Void
    let copyFeedback: ClipboardCopyFeedback?
    let canUndo: Bool
    let onUndo: () -> Void
    let snippetGroups: [ClipboardSnippetGroup]
    let snippets: [ClipboardSnippet]
    let onCopySnippet: (ClipboardSnippet) -> Void
    let onTransform: (ClipboardHistoryItem, ClipboardTextTransform) -> Void
    let onTranslate: (ClipboardHistoryItem) -> Void

    @State private var searchText = ""
    @State private var selectedItemID: UUID?
    @FocusState private var focusTarget: FocusTarget?

    private var filteredItems: [ClipboardHistoryItem] {
        ClipboardHistoryList.items(
            from: items,
            query: searchText,
            category: .all,
            sortOrder: .newestFirst
        )
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("clipboard.history"))
                        .font(.headline)
                    Text(L("clipboard.historyItems", items.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(snippetGroups) { group in
                        let groupSnippets = snippets.filter { $0.groupID == group.id }
                        if !groupSnippets.isEmpty {
                            Menu(group.name) {
                                ForEach(groupSnippets) { snippet in
                                    Button(snippet.title) { onCopySnippet(snippet) }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "text.badge.star")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .focusable(false)
                .focusEffectDisabled()
                .disabled(snippets.isEmpty)
                .help(L("clipboard.snippets"))

                Menu {
                    Button(L("clipboard.clearHistory"), action: onClearHistory)
                        .disabled(items.isEmpty)
                    Button(L("cleanup.clipboard"), action: onClearClipboard)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .focusable(false)
                .focusEffectDisabled()
                .accessibilityLabel(L("clipboard.actions"))
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("clipboard.search"), text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($focusTarget, equals: .search)
                    .onKeyPress(.escape) {
                        focusTarget = .keyboard
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(.up)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(.down)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        copySelectedItem()
                    }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 9))

            if let copyFeedback {
                let isSuccess = copyFeedback == .copied
                    || copyFeedback == .pasted
                    || copyFeedback == .clipboardCleared
                Label(
                    L(copyFeedback.localizationKey),
                    systemImage: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                    .font(.caption)
                    .foregroundStyle(isSuccess ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if canUndo {
                HStack(spacing: 8) {
                    Text(L("clipboard.removed"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("clipboard.undo"), action: onUndo)
                        .controlSize(.small)
                }
            }

            if filteredItems.isEmpty {
                ContentUnavailableView(
                    items.isEmpty ? L("clipboard.empty") : L("clipboard.noResults"),
                    systemImage: items.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                    description: Text(items.isEmpty ? L("clipboard.emptyDescription") : L("clipboard.noResultsDescription"))
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(filteredItems) { item in
                                ClipboardHistoryRow(
                                    item: item,
                                    isSelected: selectedItemID == item.id,
                                    onCopy: {
                                        selectedItemID = item.id
                                        onCopy(item)
                                    },
                                    onPerformAction: { action in onPerformAction(item, action) },
                                    onTransform: { transform in onTransform(item, transform) },
                                    onTranslate: { onTranslate(item) },
                                    onTogglePinned: { onTogglePinned(item.id) },
                                    onRemove: { onRemove(item.id) }
                                )
                                .id(item.id)
                            }
                        }
                    }
                    .onChange(of: selectedItemID) { _, selectedItemID in
                        guard let selectedItemID else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(selectedItemID, anchor: .center)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(14)
        .frame(
            minWidth: ClipboardHistoryPopoverLayout.minWidth,
            idealWidth: ClipboardHistoryPopoverLayout.idealWidth,
            maxWidth: ClipboardHistoryPopoverLayout.maxWidth,
            minHeight: ClipboardHistoryPopoverLayout.minHeight,
            idealHeight: ClipboardHistoryPopoverLayout.idealHeight,
            maxHeight: ClipboardHistoryPopoverLayout.maxHeight
        )
        .focusable()
        .focused($focusTarget, equals: .keyboard)
        .focusEffectDisabled()
        .onAppear {
            // SwiftUI 需要在 TextField 真正加入窗口后再设置焦点。
            DispatchQueue.main.async {
                focusTarget = .search
            }
        }
        .onChange(of: filteredItems.map(\.id)) { _, itemIDs in
            guard let selectedItemID,
                  !itemIDs.contains(selectedItemID) else { return }
            self.selectedItemID = nil
        }
        .onKeyPress(.escape) {
            focusTarget = .keyboard
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(.up)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(.down)
            return .handled
        }
        .onKeyPress(.return) {
            copySelectedItem()
        }
    }

    private func moveSelection(_ direction: ClipboardHistoryKeyboardNavigation.Direction) {
        selectedItemID = ClipboardHistoryKeyboardNavigation.selection(
            in: filteredItems,
            from: selectedItemID,
            moving: direction
        )
        focusTarget = .keyboard
    }

    private func copySelectedItem() -> KeyPress.Result {
        guard let item = ClipboardHistoryKeyboardNavigation.itemToCopy(
            in: filteredItems,
            selectedID: selectedItemID
        ) else {
            return .ignored
        }
        selectedItemID = item.id
        onCopy(item)
        return .handled
    }
}

struct ClipboardHistoryRow: View {
    let item: ClipboardHistoryItem
    let isSelected: Bool
    let onCopy: () -> Void
    let onPerformAction: (ClipboardHistoryAction) -> Void
    let onTransform: (ClipboardTextTransform) -> Void
    let onTranslate: () -> Void
    let onTogglePinned: () -> Void
    let onRemove: () -> Void

    @State private var isImageHovered = false

    var body: some View {
        HStack(spacing: 8) {
            contentPreview
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect(cornerRadius: 8))
                .onTapGesture(perform: onCopy)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text(L("clipboard.copy")), onCopy)

            Button(action: onTogglePinned) {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(item.isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(item.isPinned ? L("clipboard.unpin") : L("clipboard.pin"))
            .accessibilityLabel(item.isPinned ? L("clipboard.unpin") : L("clipboard.pin"))

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("clipboard.delete"))
            .accessibilityLabel(L("clipboard.delete"))

            quickActionButtons

            Menu {
                Button(L("clipboard.copy")) { onPerformAction(.copy) }
                Button(L("clipboard.paste")) { onPerformAction(.paste) }
                if item.content.plainTextRepresentation != nil {
                    Button(L("clipboard.pastePlainText")) { onPerformAction(.pastePlainText) }
                    if !item.isSensitive {
                        Menu(L("clipboard.transform")) {
                            ForEach(ClipboardTextTransform.allCases) { transform in
                                Button(L(transform.localizationKey)) { onTransform(transform) }
                            }
                        }
                        if BuiltInPluginManager.shared.isEnabled(.translation) {
                            Button(L("clipboard.translate"), action: onTranslate)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .help(L("clipboard.actions"))
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.72) : .clear,
                    lineWidth: 1
                )
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : .clear,
            in: .rect(cornerRadius: 10)
        )
    }

    @ViewBuilder
    private var quickActionButtons: some View {
        switch item.content {
        case let .url(value):
            Button { ClipboardHistoryQuickAction.openURL(value) } label: {
                Image(systemName: "safari")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("clipboard.openURL"))
        case let .files(files):
            Menu {
                Button(L("clipboard.revealInFinder")) { ClipboardHistoryQuickAction.revealFiles(files) }
                Button(L("clipboard.copyPath")) { _ = ClipboardHistoryQuickAction.copyPaths(files) }
            } label: {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
            }
        case .pdf:
            Button { _ = ClipboardHistoryService.shared.copy(item) } label: {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .help(L("clipboard.revealInFinder"))
        case .image:
            if item.recognizedText != nil {
                Menu {
                    if let recognizedText = item.recognizedText {
                        Button(L("clipboard.copyRecognizedText")) {
                            _ = ClipboardHistoryQuickAction.copyRecognizedText(recognizedText)
                        }
                    }
                    if let url = item.recognizedURLs.first {
                        Button(L("clipboard.openRecognizedQR")) { NSWorkspace.shared.open(url) }
                    }
                } label: {
                    Image(systemName: "text.viewfinder")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .help(L("clipboard.copyRecognizedText"))
            }
        case .text, .richText:
            EmptyView()
        }
    }

    @ViewBuilder
    private var contentPreview: some View {
        if item.isSensitive {
            Label(L("clipboard.sensitiveContent"), systemImage: "eye.slash.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            regularContentPreview
        }
    }

    @ViewBuilder
    private var regularContentPreview: some View {
        switch item.content {
        case let .text(text):
            Text(text)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        case let .richText(richText):
            Text(richText.plainText)
                .font(.caption)
                .lineLimit(2)
        case .pdf:
            Label(L("clipboard.pdf"), systemImage: "doc.richtext")
                .font(.caption)
                .multilineTextAlignment(.leading)
        case let .image(data):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 48)
                    .onHover { isImageHovered = $0 }
                    .popover(
                        isPresented: $isImageHovered,
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .leading
                    ) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 240, height: 180)
                            .padding(10)
                            .background(.regularMaterial, in: .rect(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
                            .allowsHitTesting(false)
                    }
            } else {
                Label(L("clipboard.image"), systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .url(value):
            Label(value, systemImage: "link")
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        case let .files(files):
            HStack(spacing: 6) {
                Image(systemName: files.count == 1 ? "doc.fill" : "doc.on.doc.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(files.first?.displayName ?? L("clipboard.files"))
                        .font(.caption)
                        .lineLimit(1)
                    if files.count > 1 {
                        Text(L("clipboard.filesCount", files.count, files.first?.displayName ?? ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    let missingCount = files.filter { !$0.isAvailable }.count
                    if missingCount > 0 {
                        Text(L("clipboard.filesMissing", missingCount))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}
