import SwiftUI

/// 系统开关的当前状态快照
struct SystemToggleStates {
    var hiddenFilesShown = false
    var muted = false
    var dockHidden = false
    var menuBarHidden = false
    var nightShift = false
}

/// 卡片错峰入场动画
private struct Entrance: ViewModifier {
    let appeared: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(Double(index) * 0.06), value: appeared)
    }
}

private extension View {
    func entrance(_ index: Int, appeared: Bool) -> some View {
        modifier(Entrance(appeared: appeared, index: index))
    }
}

/// 菜单栏弹出的主面板：液态玻璃风格，自动适配深色 / 浅色
struct MenuPanelView: View {
    @AppStorage(SettingsKey.menuBarIcon) private var menuBarIcon = MenuBarIcon.default.rawValue
    @AppStorage(SettingsKey.togglesShowTitle) private var togglesShowTitle = false
    @AppStorage(SettingsKey.preferredTerminal) private var preferredTerminal = TerminalApp.systemDefault.rawValue
    @AppStorage(SettingsKey.autoCheckUpdate) private var autoCheckUpdate = true
    @AppStorage(SettingsKey.appLanguage) private var appLanguage = AppLanguage.system.rawValue
    @Environment(\.openSettings) private var openSettings

    @ObservedObject private var caffeinate = CaffeinateService.shared
    @ObservedObject private var bleMonitor = BLEBatteryMonitor.shared
    @State private var isDarkMode = AppearanceService.isDarkMode
    @State private var btDevices: [BluetoothDeviceBattery] = []
    @State private var toggles = SystemToggleStates()
    @State private var derivedDataSize: Int64?
    @State private var isCleaningDerivedData = false
    @State private var clipboardCount = 0
    @State private var isCheckingUpdate = false
    @State private var availableUpdate: UpdateInfo?
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var appeared = false
    @State private var tooltipWidth: CGFloat = 0
    @Namespace private var glassNamespace

    private let themeChanged = DistributedNotificationCenter.default().publisher(
        for: Notification.Name("AppleInterfaceThemeChangedNotification")
    )

    var body: some View {
        VStack(spacing: 12) {
            header
                .entrance(0, appeared: appeared)

            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    heroTiles
                        .entrance(1, appeared: appeared)
                    quickToggles
                        .entrance(2, appeared: appeared)
                    bluetoothCard
                        .entrance(3, appeared: appeared)
                    cleanupTiles
                        .entrance(4, appeared: appeared)
                }
            }

            if let statusMessage {
                statusBanner(statusMessage)
            }

            footer
                .entrance(5, appeared: appeared)
        }
        .padding(16)
        .frame(width: 320)
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
                        .glassEffect(.regular, in: .capsule)
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
            refreshToggles()
            refreshDerivedDataSize()
            clipboardCount = ClipboardService.itemCount
            autoCheckUpdateIfNeeded()
            // 面板展示期间每 30 秒刷新一次蓝牙设备电量
            while !Task.isCancelled {
                bleMonitor.refresh()
                withAnimation(.smooth(duration: 0.3)) {
                    btDevices = BluetoothBatteryService.fetch()
                }
                try? await Task.sleep(for: .seconds(30))
            }
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
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(L("help.settings"))
        }
    }

    // MARK: - 主操作磁贴：终端 / 外观

    private var heroTiles: some View {
        HStack(spacing: 12) {
            Button(action: openFinderPathInTerminal) {
                heroTileLabel(
                    symbol: "terminal.fill",
                    title: L("panel.tile.terminal"),
                    subtitle: currentTerminal.shortName
                )
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.blue.opacity(0.28)).interactive(), in: .rect(cornerRadius: 18))
            .glassEffectID("terminal", in: glassNamespace)

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
            .glassEffect(
                .regular.tint((isDarkMode ? Color.indigo : Color.orange).opacity(0.28)).interactive(),
                in: .rect(cornerRadius: 18)
            )
            .glassEffectID("appearance", in: glassNamespace)
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

    // MARK: - 快捷开关带：防止锁屏 / 隐藏文件 / 静音 / 程序坞 / 菜单栏 / 夜览

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
        .glassEffectID("toggles", in: glassNamespace)
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
            symbol: toggles.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            help: L("toggle.mute"),
            isOn: toggles.muted
        ) {
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
                        withAnimation(.smooth(duration: 0.3)) {
                            btDevices = BluetoothBatteryService.fetch()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .frame(width: 22, height: 22)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
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
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .glassEffectID("bluetooth", in: glassNamespace)
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

    // MARK: - 清理磁贴：DerivedData / 剪贴板

    private var cleanupTiles: some View {
        HStack(spacing: 12) {
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
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
            .glassEffectID("derivedData", in: glassNamespace)

            Button(action: clearClipboard) {
                cleanupTileLabel(
                    symbol: "doc.on.clipboard.fill",
                    title: L("cleanup.clipboard"),
                    subtitle: clipboardSubtitle,
                    showProgress: false
                )
            }
            .buttonStyle(.plain)
            .disabled(clipboardCount == 0)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
            .glassEffectID("clipboard", in: glassNamespace)
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

    private var clipboardSubtitle: String {
        clipboardCount == 0 ? L("cleanup.clipboardEmpty") : L("cleanup.items", clipboardCount)
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
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("v\(UpdateCheckerService.currentVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let update = availableUpdate {
                Button {
                    UpdateCheckerService.openDownloadPage(update)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle.fill")
                            .symbolEffect(.bounce, value: update)
                        Text(L("footer.newVersion", update.version))
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            } else if isCheckingUpdate {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Button(L("footer.checkUpdate")) {
                    checkForUpdate()
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()
            Button(L("footer.quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
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

    private func clearClipboard() {
        ClipboardService.clear()
        withAnimation(.smooth(duration: 0.3)) {
            clipboardCount = 0
        }
        flashStatus(L("status.clipboardCleared"), isError: false)
    }

    private func checkForUpdate() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        Task {
            do {
                let update = try await UpdateCheckerService.check()
                isCheckingUpdate = false
                if let update {
                    withAnimation(.smooth(duration: 0.3)) {
                        availableUpdate = update
                    }
                    let notes = update.notes.map { " — \($0)" } ?? ""
                    flashStatus(L("status.newVersion", update.version, notes), isError: false)
                } else {
                    flashStatus(L("status.upToDate", UpdateCheckerService.currentVersion), isError: false)
                }
            } catch {
                isCheckingUpdate = false
                flashStatus(L("status.updateFailed", error.localizedDescription), isError: true)
            }
        }
    }

    /// 打开面板时的静默自动检查：可在设置中关闭；24 小时节流，只在发现新版本时提示
    private func autoCheckUpdateIfNeeded() {
        guard autoCheckUpdate, availableUpdate == nil, UpdateCheckerService.shouldAutoCheck() else { return }
        Task {
            guard let update = try? await UpdateCheckerService.check() else { return }
            withAnimation(.smooth(duration: 0.3)) {
                availableUpdate = update
            }
            flashStatus(L("status.newVersionHint", update.version), isError: false)
        }
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

/// 单个快捷开关按钮：自带悬停状态，以液态玻璃胶囊即时展示提示（替代延迟高的系统 .help 提示）
private struct QuickToggleButton: View {
    let symbol: String
    let title: String
    let isOn: Bool
    let pulse: Bool
    let showTitle: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { action() }
        } label: {
            let icon = Image(systemName: symbol)
                .font(.body.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isOn)
                .symbolEffect(.pulse, options: .repeating, isActive: pulse)
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
                icon
                    .frame(width: 40, height: 40)
                    .contentShape(.circle)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .glassEffect(
            isOn ? .regular.tint(.accentColor.opacity(0.32)).interactive() : .regular.interactive(),
            in: showTitle ? AnyShape(.rect(cornerRadius: 12)) : AnyShape(.circle)
        )
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
