import AppKit
import FinderSync

/// 菜单只负责把共享的菜单节点翻译成 `NSMenu` 并派发指令；
/// 结构、tag 快照与重投状态机都在 `RightClickExtensionSupport` 里，便于单元测试。
@objc(FinderSyncExtension)
final class FinderSyncExtension: FIFinderSync {
    private var config = RightClickConfigStore.load()
    private var registry = RightClickCommandRegistry()
    private var observers: [NSObjectProtocol] = []
    private lazy var dispatcher = RightClickCommandDispatcher(
        send: { RightClickCommandStore.send($0) },
        wake: { [weak self] completion in self?.wakeHost(completion: completion) },
        schedule: { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        })

    override init() {
        super.init()
        dispatcher.onUnavailable = { [weak self] _ in self?.reportUnavailable() }
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: Notification.Name(RightClickConfigStore.didChangeNotification), object: nil, queue: .main
        ) { [weak self] note in
            guard let config = RightClickConfigStore.decode(note.object as? String) else { return }
            guard let self else { return }
            self.config = config
            RightClickConfigStore.persist(config)
            // 宿主注册命令监听后会广播配置；冷启动较慢时，此时再投递未确认命令。
            // 同一 requestID 由宿主去重，避免与定时重试同时到达造成重复操作。
            self.dispatcher.resendPending()
        })
        observers.append(center.addObserver(
            forName: Notification.Name(RightClickCommandStore.acceptedNotification), object: nil, queue: .main
        ) { [weak self] note in
            if let id = note.object as? String { self?.dispatcher.acknowledged(requestID: id) }
        })
        center.postNotificationName(Notification.Name(RightClickConfigStore.requestNotification), object: nil, deliverImmediately: true)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        let payload = RightClickClipboardReader.payload()
        let context = menuContext(for: menuKind, payload: payload)
        let nodes = RightClickMenuBuilder.nodes(
            config: config, context: context, resources: menuResources(for: payload))
        guard !nodes.isEmpty else { return menu }
        // 保留数次菜单的指令快照；旧菜单的 tag 绝不重新映射到新动作。
        registry.prune(keeping: 2048)
        for node in nodes {
            if let item = menuItem(for: node) { menu.addItem(item) }
        }
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
            item.tag = registry.register(action.command)
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

    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let command = registry.command(forTag: sender.tag) else { return }
        dispatcher.dispatch(command)
    }

    private func wakeHost(completion: @escaping (Bool) -> Void) {
        // .app/Contents/PlugIns/扩展.appex → .app；只唤醒自身宿主。
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error == nil) }
        }
    }

    private func reportUnavailable() {
        let alert = NSAlert()
        alert.messageText = localized("rc.error.title")
        alert.informativeText = localized("rc.error.hostUnavailable")
        alert.addButton(withTitle: localized("rc.button.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
