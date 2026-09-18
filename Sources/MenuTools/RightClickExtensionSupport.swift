import AppKit
import Foundation

// MARK: - 菜单标题与运行时资源

/// 菜单标题：本地化键由调用方解析，字面量用于 PNG、Markdown 等不翻译的名称。
enum RightClickMenuTitle: Equatable, Sendable {
    case key(String)
    case literal(String)
}

struct RightClickMenuChoice: Equatable, Sendable {
    var title: RightClickMenuTitle
    var optionID: String

    init(title: RightClickMenuTitle, optionID: String) {
        self.title = title
        self.optionID = optionID
    }
}

/// 只有扩展在运行时才能确定的资源：已安装终端和当前剪贴板可导出的格式。
struct RightClickMenuResources: Equatable, Sendable {
    var terminals: [RightClickMenuChoice] = []
    var clipboardFormats: [RightClickMenuChoice] = []
}

// MARK: - 菜单节点

struct RightClickMenuAction: Equatable, Sendable {
    var title: RightClickMenuTitle
    var command: RightClickCommand
    var symbolName: String?
}

struct RightClickMenuSubmenu: Equatable, Sendable {
    var title: RightClickMenuTitle
    var symbolName: String?
    var children: [RightClickMenuNode]
}

enum RightClickMenuNode: Equatable, Sendable {
    case action(RightClickMenuAction)
    case submenu(RightClickMenuSubmenu)
}

/// 菜单结构只依赖配置与快照，扩展负责把节点翻译成 `NSMenu`。
enum RightClickMenuBuilder {
    static func nodes(config: RightClickConfig, context: RightClickMenuContext,
                      resources: RightClickMenuResources) -> [RightClickMenuNode] {
        switch config.menuStyle {
        case .flat:
            return itemNodes(config: config, context: context, resources: resources)
        case .nested:
            let children = itemNodes(config: config, context: context, resources: resources)
            return wrap(children)
        case .grouped:
            let children = groupNodes(config: config, context: context, resources: resources)
            return wrap(children)
        }
    }

    /// 默认样式：动作平铺，复制项聚合为一个子菜单并落在首个复制项的位置。
    static func itemNodes(config: RightClickConfig, context: RightClickMenuContext,
                          resources: RightClickMenuResources) -> [RightClickMenuNode] {
        let visible = RightClickMenuPolicy.visibleItems(config: config, context: context)
        let copies = visible.filter { $0.group == .copy }
        var insertedCopy = false
        var nodes: [RightClickMenuNode] = []
        for item in visible {
            if item.group == .copy {
                guard !insertedCopy else { continue }
                insertedCopy = true
                nodes.append(.submenu(.init(
                    title: .key("rc.menu.copy"), symbolName: RightClickItem.Group.copy.symbolName,
                    children: copies.compactMap {
                        node(for: $0, config: config, context: context, resources: resources)
                    })))
                continue
            }
            if let node = node(for: item, config: config, context: context, resources: resources) {
                nodes.append(node)
            }
        }
        return nodes
    }

    /// 分组样式：目录 / 复制 / 文件 三个子菜单。
    static func groupNodes(config: RightClickConfig, context: RightClickMenuContext,
                           resources: RightClickMenuResources) -> [RightClickMenuNode] {
        let visible = RightClickMenuPolicy.visibleItems(config: config, context: context)
        return RightClickItem.Group.allCases.compactMap { group in
            let items = visible.filter { $0.group == group }
            guard !items.isEmpty else { return nil }
            let children = items.compactMap {
                node(for: $0, config: config, context: context, resources: resources)
            }
            guard !children.isEmpty else { return nil }
            return .submenu(.init(title: .key(group.titleKey), symbolName: group.symbolName, children: children))
        }
    }

    static func node(for item: RightClickItem, config: RightClickConfig,
                     context: RightClickMenuContext,
                     resources: RightClickMenuResources) -> RightClickMenuNode? {
        let command = command(for: item, context: context)
        func submenu(_ choices: [RightClickMenuChoice]) -> RightClickMenuNode? {
            guard !choices.isEmpty else { return nil }
            return .submenu(.init(
                title: .key(item.titleKey), symbolName: item.symbolName,
                children: choices.map { choice in
                    var choiceCommand = command
                    choiceCommand.optionID = choice.optionID
                    return .action(.init(title: choice.title, command: choiceCommand, symbolName: nil))
                }))
        }
        switch item {
        case .newFile:
            return submenu(config.templates.map { .init(title: .literal($0.name), optionID: $0.id) })
        case .openInTerminal:
            return submenu(resources.terminals)
        case .openWithApp:
            return submenu(RightClickMenuPolicy.applications(config.applications, context: context)
                .map { .init(title: .literal($0.name), optionID: $0.id) })
        case .copyToFolder, .moveToFolder:
            return submenu(config.destinations.map { .init(title: .literal($0.name), optionID: $0.id) })
        case .saveClipboard:
            return submenu(resources.clipboardFormats)
        case .copyDirectoryListing:
            return submenu([
                .init(title: .key("rc.listing.list"), optionID: "list"),
                .init(title: .key("rc.listing.tree"), optionID: "tree"),
                .init(title: .key("rc.listing.markdown"), optionID: "markdown"),
                .init(title: .key("rc.listing.json"), optionID: "json")
            ])
        case .copyFileInfo:
            return submenu([
                .init(title: .key("rc.format.text"), optionID: "text"),
                .init(title: .literal("Markdown"), optionID: "markdown"),
                .init(title: .literal("JSON"), optionID: "json")
            ])
        case .batchRename:
            return submenu([
                .init(title: .key("rc.rename.regex"), optionID: "regex"),
                .init(title: .key("rc.rename.sequence"), optionID: "sequence"),
                .init(title: .key("rc.rename.date"), optionID: "date"),
                .init(title: .key("rc.rename.extension"), optionID: "extension")
            ])
        default:
            return .action(.init(title: .key(item.titleKey), command: command, symbolName: item.symbolName))
        }
    }

    /// 创建类动作作用在目标目录上，其余动作作用在选中项上。
    static func command(for item: RightClickItem, context: RightClickMenuContext) -> RightClickCommand {
        var paths = RightClickMenuPolicy.affectedPaths(context: context)
        if [.newFolder, .newFile, .saveClipboard, .openInTerminal].contains(item),
           let directory = RightClickMenuPolicy.targetDirectory(context: context) {
            paths = [directory]
        }
        return RightClickCommand(action: item.rawValue, paths: paths, directoryPath: context.directoryPath)
    }

    private static func wrap(_ children: [RightClickMenuNode]) -> [RightClickMenuNode] {
        guard !children.isEmpty else { return [] }
        return [.submenu(.init(title: .key("rc.menu.root"), symbolName: nil, children: children))]
    }
}

// MARK: - 菜单 tag 快照

/// 菜单打开时把指令快照绑定到 tag，点击期间 Finder 选择变化也不会误操作其他文件。
struct RightClickCommandRegistry {
    private var commands: [Int: RightClickCommand] = [:]
    private var nextTag = 1

    var count: Int { commands.count }
    var lastTag: Int { nextTag - 1 }

    mutating func register(_ command: RightClickCommand) -> Int {
        let tag = nextTag
        commands[tag] = command
        nextTag += 1
        return tag
    }

    func command(forTag tag: Int) -> RightClickCommand? { commands[tag] }

    /// 只保留最近注册的 tag；旧菜单的 tag 绝不映射到新动作。
    mutating func prune(keeping: Int) {
        guard keeping >= 0, commands.count > keeping else { return }
        let threshold = nextTag - keeping
        commands = commands.filter { $0.key >= threshold }
    }
}

// MARK: - 命令派发

/// 扩展到主 App 的命令通道：投递、未确认重投、唤醒宿主、超时提示。
/// 时间与唤醒都由外部注入，便于在无 Finder 环境下验证状态机。
/// 只在扩展主线程使用，因此不需要额外的 actor 隔离。
final class RightClickCommandDispatcher {
    typealias Send = (RightClickCommand) -> Void
    typealias Wake = (@escaping (Bool) -> Void) -> Void
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    static let retryDelay: TimeInterval = 1
    static let wakeDelay: TimeInterval = 0.5
    static let timeoutDelay: TimeInterval = 3

    private let send: Send
    private let wake: Wake
    private let schedule: Schedule

    private(set) var pending: [String: RightClickCommand] = [:]
    /// 重投与超时后仍未确认时调用，用于提示宿主不可用。
    var onUnavailable: ((String) -> Void)?

    init(send: @escaping Send, wake: @escaping Wake, schedule: @escaping Schedule) {
        self.send = send
        self.wake = wake
        self.schedule = schedule
    }

    func dispatch(_ command: RightClickCommand, requestID: String = UUID().uuidString) {
        var command = command
        command.requestID = requestID
        pending[requestID] = command
        send(command)
        schedule(Self.retryDelay) { [weak self] in
            guard let self, self.pending[requestID] != nil else { return }
            self.wakeHost(requestID: requestID, command: command)
        }
    }

    func acknowledged(requestID: String) {
        pending.removeValue(forKey: requestID)
    }

    /// 宿主注册命令监听后会广播配置；此时重投未确认命令，同一 requestID 由宿主去重。
    func resendPending() {
        for command in pending.values { send(command) }
    }

    private func wakeHost(requestID: String, command: RightClickCommand) {
        wake { [weak self] launched in
            guard let self, self.pending[requestID] != nil else { return }
            guard launched else {
                self.reportUnavailable(requestID: requestID)
                return
            }
            self.schedule(Self.wakeDelay) { [weak self] in
                guard let self, self.pending[requestID] != nil else { return }
                self.send(command)
                self.schedule(Self.timeoutDelay) { [weak self] in
                    self?.reportUnavailable(requestID: requestID)
                }
            }
        }
    }

    private func reportUnavailable(requestID: String) {
        guard pending.removeValue(forKey: requestID) != nil else { return }
        onUnavailable?(requestID)
    }
}

// MARK: - 剪贴板快照

/// 主 App 与扩展共享的剪贴板类型；扩展用它决定可导出的格式，主 App 用它写文件。
enum RightClickClipboardFormat: String, CaseIterable, Sendable {
    case txt
    case md
    case rtf
    case html
    case png

    var fileExtension: String { rawValue }
}

/// 一次剪贴板快照的全部可用表示。
struct RightClickClipboardPayload: Equatable, Sendable {
    var text: String?
    var png: Data?
    var rtf: Data?
    var html: String?

    var isEmpty: Bool { text == nil && png == nil && rtf == nil && html == nil }

    /// 菜单里可用的导出格式；顺序固定，便于测试与显示。
    var availableFormats: [RightClickClipboardFormat] {
        var formats: [RightClickClipboardFormat] = []
        if png != nil { formats.append(.png) }
        if text != nil { formats.append(.txt); formats.append(.md) }
        if rtf != nil { formats.append(.rtf) }
        if html != nil { formats.append(.html) }
        return formats
    }

    func data(for format: RightClickClipboardFormat) -> Data? {
        switch format {
        case .txt, .md: return text.map { Data($0.utf8) }
        case .rtf: return rtf
        case .html: return html.map { Data($0.utf8) }
        case .png: return png
        }
    }
}

/// 旧接口：文本或图片的单一快照，供模板变量和菜单可见性使用。
enum RightClickClipboardSnapshot: Equatable, Sendable {
    case text(String)
    case image(Data)
}

enum RightClickClipboardReader {
    /// 文件引用不作为内容；图片按 PNG、纯文本优先，富文本不会顶掉模板里的纯文本。
    static func read(from pasteboard: NSPasteboard = .general) -> RightClickClipboardSnapshot? {
        guard let payload = payload(from: pasteboard) else { return nil }
        if let png = payload.png { return .image(png) }
        if let text = payload.text { return .text(text) }
        return nil
    }

    static func payload(from pasteboard: NSPasteboard = .general) -> RightClickClipboardPayload? {
        guard pasteboard.availableType(from: [.fileURL]) == nil else { return nil }
        var payload = RightClickClipboardPayload()
        payload.png = pngData(from: pasteboard)
        if let string = pasteboard.string(forType: .string), !string.isEmpty { payload.text = string }
        if payload.png == nil, let data = pasteboard.data(forType: .rtf), !data.isEmpty,
           data.count <= 5 * 1024 * 1024 {
            payload.rtf = data
        }
        if payload.png == nil, let html = pasteboard.string(forType: .html), !html.isEmpty,
           html.utf8.count <= 5 * 1024 * 1024 {
            payload.html = html
        }
        return payload.isEmpty ? nil : payload
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type),
                  let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            return png
        }
        return nil
    }
}
