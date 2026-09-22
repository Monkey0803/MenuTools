import AppKit
import SwiftUI

enum ClipboardQuickAccessPresentationPolicy {
    static func shouldShow(isShown: Bool) -> Bool {
        !isShown
    }
}

enum AppVolumeQuickAccessPresentationPolicy {
    static func shouldShow(isShown: Bool) -> Bool {
        !isShown
    }
}

enum WindowManagementQuickAccessPresentationPolicy {
    static func shouldShow(isShown: Bool) -> Bool {
        !isShown
    }
}

/// 状态项是快捷弹窗的锚点：展示期间标题里不带 App 名，宽度才不会随名字长度变化。
/// 名字只影响宽度、不影响数值，百分比依旧实时跟随音量。
enum MenuBarStatusItemTitlePolicy {
    static func showsAppName(isQuickAccessPresented: Bool) -> Bool {
        !isQuickAccessPresented
    }
}

/// 状态项标题排版：宽度必须恒定，否则锚定其上的弹窗会跟着位移、菜单栏也会重排。
enum MenuBarStatusItemTitleLayout {
    /// 等宽数字字体：`1` 与 `0` 等宽，百分比位数变化不会改变标题宽度。
    /// 用计算属性而非 `static let`：NSFont 不是 Sendable，避免全局共享状态检查报错。
    static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    static func width(of title: String) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: font]).width
    }
}

/// 使用 AppKit 直接管理菜单栏入口，避免 SwiftUI MenuBarExtra 在部分 macOS 版本上丢失鼠标点击。
@MainActor
final class MenuBarStatusItemController: NSObject {
    static let shared = MenuBarStatusItemController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var clipboardPopover: NSPopover?
    private var appVolumePopover: NSPopover?
    private var windowManagementPopover: NSPopover?
    private var settingsWindowController: NSWindowController?
    private var settingsHostingController: NSHostingController<SettingsView>?
    private var defaultsObserver: NSObjectProtocol?
    private var networkTrafficObserver: NSObjectProtocol?
    private var appVolumeObserver: NSObjectProtocol?

    override init() {
        super.init()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateButton()
            }
        }
        networkTrafficObserver = NotificationCenter.default.addObserver(
            forName: .networkTrafficSnapshotDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateButton()
            }
        }
        appVolumeObserver = NotificationCenter.default.addObserver(
            forName: .appVolumeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateButton()
            }
        }
    }

    func start() {
        guard statusItem == nil else {
            updateButton()
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseUp])
        updateButton()
    }

    /// 弹窗（含主面板）都锚定在状态项上：展示期间标题不带 App 名，宽度才不会变。
    private var isQuickAccessPresented: Bool {
        [popover, clipboardPopover, appVolumePopover, windowManagementPopover]
            .contains { $0?.isShown == true }
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }

        let iconName = UserDefaults.standard.string(forKey: SettingsKey.menuBarIcon)
            ?? MenuBarIcon.default.rawValue
        let showTitle = UserDefaults.standard.bool(forKey: SettingsKey.menuBarShowTitle)
        let trafficMode = UserDefaults.standard.string(forKey: NetworkTrafficSettingsKey.menuBarDisplayMode)
            .flatMap(NetworkTrafficMenuBarDisplayMode.init(rawValue:)) ?? .off
        let trafficTitle = BuiltInPluginManager.shared.isEnabled(.networkTraffic)
            ? NetworkTrafficMenuBarPresenter.title(
                snapshot: NetworkTrafficService.shared.snapshot,
                mode: trafficMode
            )
            : nil

        let volumeMode = UserDefaults.standard.string(forKey: AppVolumeService.StorageKey.menuBarDisplayMode)
            .flatMap(AppVolumeMenuBarDisplayMode.init(rawValue:)) ?? .off
        // 面板展示期间状态项是弹窗锚点，标题不带 App 名，宽度才不会随名字变化。
        let showsAppName = MenuBarStatusItemTitlePolicy.showsAppName(
            isQuickAccessPresented: isQuickAccessPresented
        )
        let volumeTitle: String? = BuiltInPluginManager.shared.isEnabled(.appVolume)
            ? AppVolumeMenuBarPresenter.title(
                mode: volumeMode,
                masterVolume: AppVolumeService.shared.output.volume,
                isMuted: AppVolumeService.shared.output.isMuted,
                loudest: AppVolumeService.shared.loudestActiveApp,
                showsAppName: showsAppName
            )
            : nil

        // 统一选择器决定显示哪一项；未设置（.automatic）时沿用旧行为：网速优先，其次音量。
        let unified = UserDefaults.standard.string(forKey: SettingsKey.menuBarMetric)
            .flatMap(MenuBarMetric.init(rawValue:))
        // 菜单栏显示资源指标时需要后台采样（10 秒档），选择变化时在这里同步。
        SystemResourceService.shared.refreshBackgroundSampling()
        let metric = MenuBarMetricResolver.resolve(
            unified: unified,
            trafficModeOff: trafficMode == .off,
            volumeModeOff: volumeMode == .off
        )
        let resourceTitle = BuiltInPluginManager.shared.isEnabled(.systemResources)
            ? SystemResourceMenuBarPresenter.title(
                snapshot: SystemResourceService.shared.snapshot,
                metric: metric
            )
            : nil
        let title: String?
        switch metric {
        case .networkSpeed:
            title = trafficTitle
        case .volume:
            title = volumeTitle
        case .cpu, .memory, .disk:
            title = resourceTitle
        case .automatic, .off:
            title = nil
        }

        button.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: "MenuTools"
        )
        button.image?.isTemplate = true
        // 用等宽数字字体设置标题：数字宽度一致，标题宽度才不会随音量数值变化。
        let displayTitle = title ?? (showTitle ? "MenuTools" : "")
        button.attributedTitle = NSAttributedString(
            string: displayTitle,
            attributes: [.font: MenuBarStatusItemTitleLayout.font]
        )
        button.imagePosition = displayTitle.isEmpty ? .imageOnly : .imageLeft
        button.toolTip = title.map { "MenuTools · \($0)" } ?? "MenuTools"
        button.setAccessibilityLabel(button.toolTip ?? "MenuTools")
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        try? Data("toggle".utf8).write(to: URL(fileURLWithPath: "/tmp/menutools-status-toggle.marker"))

        if BuiltInPluginManager.shared.isEnabled(.windowManagement) {
            WindowManagementService.shared.rememberFrontmostExternalApplication()
        }

        if let popover, popover.isShown {
            popover.performClose(button)
            return
        }

        let popover = Self.reusablePopover(existing: popover) { [weak self] in
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = NSSize(width: MenuPanelLayout.width, height: MenuPanelLayout.height)
            popover.contentViewController = NSHostingController(
                rootView: MenuPanelView { [weak self] tab in
                    self?.openSettings(tab)
                }
            )
            return popover
        }
        self.popover = popover
        popover.delegate = self

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            Self.configurePopoverWindow(window)
        }
    }

    /// 快捷键可继续顺序粘贴；从主面板打开历史时只展示，不消费待粘贴条目。
    func showClipboardHistory(advancingSequentialPaste: Bool = true) {
        guard BuiltInPluginManager.shared.isEnabled(.clipboard),
              let button = statusItem?.button else {
            return
        }

        ClipboardAutoPasteTargetTracker.shared.rememberFrontmostApplication()

        if advancingSequentialPaste, ClipboardHistoryService.shared.hasActiveSequentialPaste {
            _ = ClipboardHistoryService.shared.pasteNextSequentialItem()
            return
        }

        guard ClipboardQuickAccessPresentationPolicy.shouldShow(
            isShown: clipboardPopover?.isShown == true
        ) else { return }
        if let appVolumePopover, appVolumePopover.isShown {
            appVolumePopover.performClose(button)
        }
        if let popover, popover.isShown {
            popover.performClose(button)
        }

        let clipboardPopover = Self.reusablePopover(existing: clipboardPopover) { [weak self] in
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = NSSize(width: 328, height: 388)
            popover.contentViewController = NSHostingController(
                rootView: ClipboardHistoryQuickAccessView(selectionAction: .paste) { [weak self] in
                    guard let self, let button = self.statusItem?.button else { return }
                    self.clipboardPopover?.performClose(button)
                }
            )
            return popover
        }
        self.clipboardPopover = clipboardPopover
        clipboardPopover.delegate = self
        clipboardPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = clipboardPopover.contentViewController?.view.window {
            Self.configurePopoverWindow(window)
        }
    }

    /// 供 App 音量插件的全局快捷键直接调出音量管理面板。
    func showAppVolume() {
        guard BuiltInPluginManager.shared.isEnabled(.appVolume),
              let button = statusItem?.button else {
            return
        }

        guard AppVolumeQuickAccessPresentationPolicy.shouldShow(
            isShown: appVolumePopover?.isShown == true
        ) else { return }
        if let clipboardPopover, clipboardPopover.isShown {
            clipboardPopover.performClose(button)
        }
        if let popover, popover.isShown {
            popover.performClose(button)
        }

        let appVolumePopover = Self.reusablePopover(existing: appVolumePopover) {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = NSSize(width: 328, height: 388)
            popover.contentViewController = NSHostingController(
                rootView: AppVolumeQuickAccessView()
            )
            return popover
        }
        self.appVolumePopover = appVolumePopover
        appVolumePopover.delegate = self
        appVolumePopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = appVolumePopover.contentViewController?.view.window {
            Self.configurePopoverWindow(window)
        }
    }

    /// 供窗口管理插件的全局快捷键直接调出布局选择面板。
    func showWindowManagement() {
        guard BuiltInPluginManager.shared.isEnabled(.windowManagement),
              let button = statusItem?.button else {
            return
        }

        // 全局快捷键到达时仍是外部应用处于前台；在展示本面板之前保留它。
        WindowManagementService.shared.rememberFrontmostExternalApplication()
        guard WindowManagementQuickAccessPresentationPolicy.shouldShow(
            isShown: windowManagementPopover?.isShown == true
        ) else { return }
        if let clipboardPopover, clipboardPopover.isShown {
            clipboardPopover.performClose(button)
        }
        if let appVolumePopover, appVolumePopover.isShown {
            appVolumePopover.performClose(button)
        }
        if let popover, popover.isShown {
            popover.performClose(button)
        }

        let windowManagementPopover = Self.reusablePopover(existing: windowManagementPopover) { [weak self] in
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = NSSize(width: 340, height: 430)
            popover.contentViewController = NSHostingController(
                rootView: WindowManagementQuickAccessView {
                    guard let self, let button = self.statusItem?.button else { return }
                    self.windowManagementPopover?.performClose(button)
                }
            )
            return popover
        }
        self.windowManagementPopover = windowManagementPopover
        windowManagementPopover.delegate = self
        windowManagementPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = windowManagementPopover.contentViewController?.view.window {
            Self.configurePopoverWindow(window)
        }
    }

    /// 关闭 Popover 时保留 SwiftUI 视图树，后续打开不再重复初始化全部服务和玻璃层级。
    static func reusablePopover(
        existing: NSPopover?,
        create: () -> NSPopover
    ) -> NSPopover {
        existing ?? create()
    }

    /// NSPopover 默认会绘制一层不透明的窗口灰底；控制中心风格卡片之间应直接
    /// 透出桌面材质，避免滚动区域形成一整块灰色矩形。
    static func configurePopoverWindow(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func openSettings(_ tab: SettingsTab = .general) {
        if BuiltInPluginManager.shared.isEnabled(.windowManagement) {
            WindowManagementService.shared.rememberFrontmostExternalApplication()
        }
        // transient popover 会在当前鼠标事件结束时自动关闭。先显式关闭，再把设置窗口
        // 延迟到下一个 run loop 展示，避免 popover 的关闭流程覆盖窗口的前置操作。
        if let button = statusItem?.button, let popover, popover.isShown {
            popover.performClose(button)
        }

        DispatchQueue.main.async { [weak self] in
            self?.presentSettingsWindow(initialTab: tab)
        }
    }

    /// 供 `menutools://settings` 深链及外部自动化跳转到指定设置页。
    func showSettings(_ tab: SettingsTab = .general) {
        openSettings(tab)
    }

    private func presentSettingsWindow(initialTab: SettingsTab) {
        if let window = settingsWindowController?.window {
            settingsHostingController?.rootView = SettingsView(initialTab: initialTab)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView(initialTab: initialTab))
        settingsHostingController = hostingController
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: SettingsLayout.windowWidth, height: SettingsLayout.windowHeight)
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = L("settings.title")
        window.setContentSize(NSSize(width: SettingsLayout.windowWidth, height: SettingsLayout.windowHeight))
        // 设置窗口只在打开时置前，使用普通层级，避免长期覆盖其他应用窗口。
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
    }
}

extension MenuBarStatusItemController: NSPopoverDelegate {
    /// 弹窗展示期间标题不带 App 名（宽度恒定），关闭后恢复显示名字。
    func popoverDidShow(_ notification: Notification) {
        updateButton()
    }

    func popoverDidClose(_ notification: Notification) {
        updateButton()
    }
}
