import AppKit
import FinderSync

/// Finder 右键扩展主类：根据共享配置动态构建右键菜单，执行文件操作
@objc(FinderSyncExtension)
final class FinderSyncExtension: FIFinderSync {

    private var config = RightClickConfigStore.load()

    override init() {
        super.init()
        // 监控整个用户目录，使右键菜单在任意位置可用
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: NSHomeDirectory()),
            URL(fileURLWithPath: "/Volumes")
        ]
        // 配置变更时热重载
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(RightClickConfigStore.didChangeNotification),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.config = RightClickConfigStore.load()
        }
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

    private func selector(for item: RightClickItem) -> Selector {
        switch item {
        case .newFolder: return #selector(newFolder(_:))
        case .newFile: return #selector(newFile(_:))
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

    // MARK: - 目录操作

    @objc private func newFolder(_ sender: AnyObject?) {
        let base = targetDirectory
        let url = uniqueURL(in: base, name: NSLocalizedString("rc.default.newFolder", comment: ""), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    @objc private func newFile(_ sender: AnyObject?) {
        let base = targetDirectory
        let url = uniqueURL(in: base, name: NSLocalizedString("rc.default.newFile", comment: ""), isDirectory: false)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    @objc private func openInTerminal(_ sender: AnyObject?) {
        let dir = selectedURLs.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true })
            ?? targetDirectory
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: config)
        }
    }

    // MARK: - 复制操作

    @objc private func copyFilename(_ sender: AnyObject?) {
        copyToPasteboard(affectedURLs.map { $0.lastPathComponent })
    }

    @objc private func copyAbsolutePath(_ sender: AnyObject?) {
        copyToPasteboard(affectedURLs.map { $0.path })
    }

    @objc private func copyRelativePath(_ sender: AnyObject?) {
        let base = targetDirectory.path
        copyToPasteboard(affectedURLs.map { url in
            url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent
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

    /// 在目录下生成不重名的路径（重名追加序号）
    private func uniqueURL(in directory: URL, name: String, isDirectory: Bool) -> URL {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            index += 1
        }
        return candidate
    }
}
