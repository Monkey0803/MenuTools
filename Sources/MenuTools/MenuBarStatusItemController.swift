import AppKit
import SwiftUI

/// 使用 AppKit 直接管理菜单栏入口，避免 SwiftUI MenuBarExtra 在部分 macOS 版本上丢失鼠标点击。
@MainActor
final class MenuBarStatusItemController: NSObject {
    static let shared = MenuBarStatusItemController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var settingsWindowController: NSWindowController?
    private var settingsHostingController: NSHostingController<SettingsView>?
    private var defaultsObserver: NSObjectProtocol?

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

    private func updateButton() {
        guard let button = statusItem?.button else { return }

        let iconName = UserDefaults.standard.string(forKey: SettingsKey.menuBarIcon)
            ?? MenuBarIcon.default.rawValue
        let showTitle = UserDefaults.standard.bool(forKey: SettingsKey.menuBarShowTitle)

        button.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: "MenuTools"
        )
        button.image?.isTemplate = true
        button.title = showTitle ? "MenuTools" : ""
        button.imagePosition = showTitle ? .imageLeft : .imageOnly
        button.toolTip = "MenuTools"
        button.setAccessibilityLabel("MenuTools")
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

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 352, height: 672)
        popover.contentViewController = NSHostingController(
            rootView: MenuPanelView { [weak self] tab in
                self?.openSettings(tab)
            }
        )
        self.popover = popover

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            Self.configurePopoverWindow(window)
        }
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
