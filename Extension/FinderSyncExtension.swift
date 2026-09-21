import AppKit
import FinderSync

/// 菜单只负责把共享的菜单节点翻译成 `NSMenu` 并派发指令；
/// 结构、tag 快照与重投状态机都在 `RightClickExtensionSupport` 里，便于单元测试。
///
/// 线程模型：Finder 在 XPC 线程上调用 `menu(for:)`；配置广播、点击派发与重投走主队列。
/// 因此配置快照与 tag 表用 `RightClickLockedState` 保护，`dispatcher` 只在主队列使用。
@objc(FinderSyncExtension)
final class FinderSyncExtension: FIFinderSync {
    private let configState: RightClickLockedState<RightClickConfig>
    private let registryState = RightClickLockedState(RightClickCommandRegistry())
    private var observers: [NSObjectProtocol] = []
    private lazy var dispatcher = RightClickCommandDispatcher(
        send: { RightClickCommandStore.send($0) },
        wake: { [weak self] completion in self?.wakeHost(completion: completion) },
        schedule: { delay, work in
            // GCD 的闭包要求 @Sendable，而重投状态机只在主队列使用：
            // 用 MainThreadBox 把主队列上创建的工作转交给主队列执行。
            let box = MainThreadBox(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { box.value() }
        })

    override init() {
        // 冷启动先读本进程的配置缓存，并把日志开关同步给 logger（沙盒扩展读不到 App 的设置）
        let initialConfig = RightClickConfigStore.load()
        configState = RightClickLockedState(initialConfig)
        super.init()
        RightClickLogger.apply(initialConfig)
        dispatcher.onUnavailable = { [weak self] _ in self?.reportUnavailable() }
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        let center = DistributedNotificationCenter.default()
        // 观察者闭包在 .main 队列上执行，用 weak box 避免持有 self 造成环。
        let box = WeakMainThreadBox(self)
        observers.append(center.addObserver(
            forName: Notification.Name(RightClickConfigStore.didChangeNotification), object: nil, queue: .main
        ) { note in
            guard let config = RightClickConfigStore.decode(note.object as? String) else { return }
            guard let self = box.value else { return }
            MainActor.assumeIsolated {
                self.configState.mutate { $0 = config }
                RightClickLogger.apply(config)
                RightClickConfigStore.persist(config)
                // 宿主注册命令监听后会广播配置；冷启动较慢时，此时再投递未确认命令。
                // 同一 requestID 由宿主去重，避免与定时重试同时到达造成重复操作。
                self.dispatcher.resendPending()
            }
        })
        observers.append(center.addObserver(
            forName: Notification.Name(RightClickCommandStore.acceptedNotification), object: nil, queue: .main
        ) { note in
            guard let id = note.object as? String else { return }
            MainActor.assumeIsolated { box.value?.dispatcher.acknowledged(requestID: id) }
        })
        center.postNotificationName(Notification.Name(RightClickConfigStore.requestNotification), object: nil, deliverImmediately: true)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        // Finder 通过 XPC 在**后台线程**调用这里（不是主线程），
        // 所以埋点必须走线程安全的 RightClickPerformanceMonitor，不能假设主 actor。
        // 每次菜单构建独占一个计时会话，Finder 并发请求也不会交叉累计。
        let monitor = RightClickPerformanceMonitor { RightClickLogger.forwardToHost($0) }
        monitor.beginPhase("menu_start")

        // 取一次配置快照：构建期间配置可能被主队列的广播替换，快照保证同一次菜单一致。
        let config = configState.read()

        let menu = NSMenu(title: "")
        let payload = RightClickClipboardReader.payload()

        monitor.endPhase("payload_read")

        let context = menuContext(for: menuKind, payload: payload)

        monitor.endPhase("context_build")

        let nodes = RightClickMenuBuilder.nodes(
            config: config, context: context, resources: menuResources(for: payload))

        monitor.endPhase("nodes_build")

        guard !nodes.isEmpty else {
            monitor.report()
            return menu
        }

        // 保留数次菜单的指令快照；旧菜单的 tag 绝不重新映射到新动作。
        registryState.mutate { $0.prune(keeping: 2048) }
        for node in nodes {
            if let item = menuItem(for: node) { menu.addItem(item) }
        }

        monitor.endPhase("menu_render")
        monitor.report()

        return menu
    }

    private func menuContext(for menuKind: FIMenuKind,
                             payload: RightClickClipboardPayload?) -> RightClickMenuContext {
        let controller = FIFinderSyncController.default()
        let targetURL = controller.targetedURL()
        let selected: [URL]
        if menuKind == .contextualMenuForContainer { selected = [] }
        else if menuKind == .contextualMenuForSidebar { selected = targetURL.map { [$0] } ?? [] }
        else { selected = controller.selectedItemURLs() ?? [] }
        let selection = selected.map(selection(from:))
        let target = targetURL.map(selection(from:))
        let directory = RightClickMenuPolicy.browsingDirectory(
            target: target, selection: selection, isContainer: menuKind == .contextualMenuForContainer)
        return RightClickMenuContext(
            directoryPath: directory, selection: selection, clipboard: clipboardKind(for: payload))
    }

    private func menuResources(for payload: RightClickClipboardPayload?) -> RightClickMenuResources {
        var terminals: [RightClickMenuChoice] = [
            .init(title: .key("rc.terminal.default"), optionID: TerminalApp.defaultOptionID)
        ]
        terminals += TerminalApp.allCases.compactMap { terminal in
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.rawValue) != nil else {
                return nil
            }
            let name = terminal == .terminal ? localized("terminal.builtin") : terminal.shortName
            return .init(title: .literal(name), optionID: terminal.rawValue)
        }
        return RightClickMenuResources(
            terminals: terminals, clipboardFormats: clipboardFormats(for: payload))
    }

    private func clipboardFormats(for payload: RightClickClipboardPayload?) -> [RightClickMenuChoice] {
        guard let payload else { return [] }
        return payload.availableFormats.map { format in
            switch format {
            case .txt: return .init(title: .literal("TXT"), optionID: format.rawValue)
            case .md: return .init(title: .literal("Markdown"), optionID: format.rawValue)
            case .rtf: return .init(title: .literal("RTF"), optionID: format.rawValue)
            case .html: return .init(title: .literal("HTML"), optionID: format.rawValue)
            case .png: return .init(title: .literal("PNG"), optionID: format.rawValue)
            }
        }
    }

    private func menuItem(for node: RightClickMenuNode) -> NSMenuItem? {
        switch node {
        case .action(let action):
            let item = NSMenuItem(title: title(action.title), action: #selector(performCommand(_:)), keyEquivalent: "")
            item.target = self
            item.image = symbolImage(action.symbolName)
            item.tag = registryState.mutate { $0.register(action.command) }
            return item
        case .submenu(let submenu):
            let parent = NSMenuItem(title: title(submenu.title), action: nil, keyEquivalent: "")
            parent.image = symbolImage(submenu.symbolName)
            let children = NSMenu(title: parent.title)
            for child in submenu.children {
                if let item = menuItem(for: child) { children.addItem(item) }
            }
            guard !children.items.isEmpty else { return nil }
            parent.submenu = children
            return parent
        }
    }

    /// AppKit 在主线程派发菜单动作；tag 表可能刚被 XPC 线程写入，所以走同一把锁读。
    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let command = registryState.read().command(forTag: sender.tag) else { return }
        dispatcher.dispatch(command)
    }

    private func wakeHost(completion: @escaping (Bool) -> Void) {
        // .app/Contents/PlugIns/扩展.appex → .app；只唤醒自身宿主。
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let box = MainThreadBox(completion)
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            let launched = error == nil
            DispatchQueue.main.async { box.value(launched) }
        }
    }

    private func reportUnavailable() {
        // 文案先取出来，避免把 self 送进主 actor；弹窗显式回主队列，
        // 这样即使调用方不在主线程也只会延后显示，不会命中 assumeIsolated 断言。
        let title = localized("rc.error.title")
        let message = localized("rc.error.hostUnavailable")
        let button = localized("rc.button.ok")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = message
                alert.addButton(withTitle: button)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    private func clipboardKind(for payload: RightClickClipboardPayload?) -> RightClickClipboardKind {
        guard let payload else { return .none }
        if payload.png != nil { return .image }
        return .text
    }

    private func selection(from url: URL) -> RightClickSelection {
        RightClickSelection(
            path: url.path,
            isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
    }

    private func title(_ title: RightClickMenuTitle) -> String {
        switch title {
        case .key(let key): return localized(key)
        case .literal(let value): return value
        }
    }

    private func symbolImage(_ name: String?) -> NSImage? {
        guard let name else { return nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func localized(_ key: String) -> String { NSLocalizedString(key, comment: "") }
}

// MARK: - 主线程转交

// 扩展的所有状态（配置、tag 快照、重投状态机）都只在主线程读写，但 GCD 与
// AppKit 的完成回调要求 `@Sendable` 闭包。用这两个极小的盒子把主线程上创建
// 的值带过去，就不必给整个类型声明 `@unchecked Sendable`。

/// 把主线程上创建的值交给需要 `@Sendable` 的闭包；值仍然只在主线程使用。
private final class MainThreadBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// 同上，但不持有对象，避免观察者闭包与 `self` 形成环。
private final class WeakMainThreadBox<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}
