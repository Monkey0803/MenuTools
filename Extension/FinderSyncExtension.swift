import AppKit
import FinderSync

/// 新建文件可选类型（子菜单顺序即 tag 值）
private let newFileTypes = ["txt", "md", "json", "yaml", "xml", "csv", "html", "css", "js", "py", "sh"]

/// Finder 右键扩展主类：根据共享配置动态构建右键菜单，执行文件操作
@objc(FinderSyncExtension)
final class FinderSyncExtension: FIFinderSync {

    private var config = RightClickConfigStore.load()

    override init() {
        super.init()
        // 监控整个文件系统，使右键菜单在任意位置可用。
        // 注意：扩展跑在沙箱里，NSHomeDirectory() 返回的是沙箱容器路径而非真实用户目录，
        // 监控它会导致菜单在真实目录中永远不出现；directoryURLs 只是菜单作用域声明，
        // 不需要文件访问权限，直接监控 "/" 即可覆盖所有位置（含外置卷）。
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: "/")
        ]
        // 配置变更时热重载：配置随通知 object 广播而来，缓存到自身沙箱容器供冷启动用
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(RightClickConfigStore.didChangeNotification),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let config = RightClickConfigStore.decode(note.object as? String) else { return }
            self?.config = config
            RightClickConfigStore.persist(config)
        }
        // 冷启动时向主 App 要一次最新配置（本地缓存可能落后）
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(RightClickConfigStore.requestNotification), object: nil, deliverImmediately: true
        )
    }

    // MARK: - 菜单构建

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        let items = config.enabledItems
        guard !items.isEmpty else { return menu }

        let root = NSMenuItem(title: "MenuTools", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "MenuTools")

        // 按分组插入，分组间加分隔线
        var lastGroup: RightClickItem.Group?
        for item in items {
            if let last = lastGroup, last != item.group {
                submenu.addItem(.separator())
            }
            let menuItem = NSMenuItem(title: title(for: item), action: selector(for: item), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.rawValue
            // 新建文件提供类型子菜单（.txt / .md / .json）
            if item == .newFile {
                menuItem.action = nil
                let typeMenu = NSMenu(title: menuItem.title)
                for (index, ext) in newFileTypes.enumerated() {
                    // 文本 / 数据 / 代码三类之间加分隔线
                    if ext == "json" || ext == "html" {
                        typeMenu.addItem(.separator())
                    }
                    let typeItem = NSMenuItem(title: ".\(ext)", action: #selector(newFileWithType(_:)), keyEquivalent: "")
                    typeItem.target = self
                    // FinderSync 菜单跨进程序列化，representedObject 不会保留，只能用 tag 传类型
                    typeItem.tag = index
                    typeMenu.addItem(typeItem)
                }
                menuItem.submenu = typeMenu
            }
            submenu.addItem(menuItem)
            lastGroup = item.group
        }
        root.submenu = submenu
        menu.addItem(root)
        return menu
    }

    private func title(for item: RightClickItem) -> String {
        // 扩展进程用主 bundle 的本地化（随系统语言）
        NSLocalizedString(item.titleKey, comment: "")
    }

    private func selector(for item: RightClickItem) -> Selector? {
        switch item {
        case .newFolder: return #selector(newFolder(_:))
        case .newFile: return nil  // 由类型子菜单承担动作
        case .openInTerminal: return #selector(openInTerminal(_:))
        case .copyFilename: return #selector(copyFilename(_:))
        case .copyAbsolutePath: return #selector(copyAbsolutePath(_:))
        case .copyRelativePath: return #selector(copyRelativePath(_:))
        case .copyEscapedPath: return #selector(copyEscapedPath(_:))
        case .copyFileURL: return #selector(copyFileURL(_:))
        }
    }

    // MARK: - 目标目录 / 选中项

    /// 右键点击的目标目录（选中文件夹或当前浏览目录）
    private var targetDirectory: URL {
        FIFinderSyncController.default().targetedURL()
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private var selectedURLs: [URL] {
        FIFinderSyncController.default().selectedItemURLs() ?? []
    }

    /// 复制类操作作用的对象：优先选中项，否则当前目录
    private var affectedURLs: [URL] {
        let selected = selectedURLs
        return selected.isEmpty ? [targetDirectory] : selected
    }

    // MARK: - 目录操作（转交主 App 执行：沙箱扩展无任意目录写权限，也无法携目录打开终端）

    private func relay(_ item: RightClickItem, paths: [String], fileExtension: String? = nil) {
        RightClickCommandStore.send(
            RightClickCommand(action: item.rawValue, paths: paths, fileExtension: fileExtension)
        )
    }

    @objc private func newFolder(_ sender: AnyObject?) {
        relay(.newFolder, paths: [targetDirectory.path])
    }

    @objc private func newFileWithType(_ sender: NSMenuItem) {
        let index = sender.tag
        let ext = newFileTypes.indices.contains(index) ? newFileTypes[index] : "txt"
        relay(.newFile, paths: [targetDirectory.path], fileExtension: ext)
    }

    @objc private func openInTerminal(_ sender: AnyObject?) {
        let dir = selectedURLs.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true })
            ?? targetDirectory
        relay(.openInTerminal, paths: [dir.path])
    }

    // MARK: - 复制操作

    @objc private func copyFilename(_ sender: AnyObject?) {
        copyToPasteboard(affectedURLs.map { $0.lastPathComponent })
    }

    @objc private func copyAbsolutePath(_ sender: AnyObject?) {
        copyToPasteboard(affectedURLs.map { $0.path })
    }

    @objc private func copyRelativePath(_ sender: AnyObject?) {
        // 相对用户目录的 ~ 路径；沙箱里 NSHomeDirectory() 是容器路径，真实用户目录要从 passwd 取
        let home = realHomeDirectory()
        copyToPasteboard(affectedURLs.map { url in
            let path = url.path
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
            return path
        })
    }

    @objc private func copyEscapedPath(_ sender: AnyObject?) {
        // 转义空格与特殊字符，适合直接粘贴到终端
        copyToPasteboard(affectedURLs.map { escapeForShell($0.path) })
    }

    @objc private func copyFileURL(_ sender: AnyObject?) {
        copyToPasteboard(affectedURLs.map { $0.absoluteString })
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ items: [String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(items.joined(separator: "\n"), forType: .string)
    }

    private func escapeForShell(_ path: String) -> String {
        // 用单引号包裹，内部单引号做转义
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 真实用户目录：沙箱进程下 NSHomeDirectory() 返回容器路径，getpwuid 不受影响
    private func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }
}
