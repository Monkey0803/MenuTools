import Foundation

/// Finder 右键工具的配置项 Key（与菜单动作一一对应）
enum RightClickItem: String, CaseIterable, Identifiable, Codable {
    // 目录操作
    case newFolder
    case newFile
    case openInTerminal
    // 复制菜单项
    case copyFilename
    case copyAbsolutePath
    case copyRelativePath
    case copyEscapedPath
    case copyFileURL

    var id: String { rawValue }

    /// 本地化标题 Key
    var titleKey: String { "rc.item.\(rawValue)" }
    /// 本地化副标题 Key（无则返回 nil）
    var subtitleKey: String? {
        switch self {
        case .newFile: return "rc.item.newFile.desc"
        case .copyRelativePath: return "rc.item.copyRelativePath.desc"
        case .copyEscapedPath: return "rc.item.copyEscapedPath.desc"
        default: return nil
        }
    }

    /// 所属分组
    enum Group: String, CaseIterable, Identifiable {
        case directory
        case copy
        var id: String { rawValue }
        var titleKey: String { "rc.group.\(rawValue)" }
    }

    var group: Group {
        switch self {
        case .newFolder, .newFile, .openInTerminal: return .directory
        case .copyFilename, .copyAbsolutePath, .copyRelativePath, .copyEscapedPath, .copyFileURL: return .copy
        }
    }
}

/// App 与 Finder 扩展共享的配置：以 JSON 存于 Application Support，
/// 扩展进程（非沙箱）与主 App 都读写同一文件，实现跨进程同步
struct RightClickConfig: Codable, Equatable, Sendable {
    /// 各菜单项是否启用（缺省视为启用）
    var enabled: [String: Bool]

    static let `default` = RightClickConfig(
        enabled: Dictionary(uniqueKeysWithValues: RightClickItem.allCases.map { ($0.rawValue, true) })
    )

    func isEnabled(_ item: RightClickItem) -> Bool {
        enabled[item.rawValue] ?? true
    }

    /// 已启用的菜单项（按枚举声明顺序）
    var enabledItems: [RightClickItem] {
        RightClickItem.allCases.filter { isEnabled($0) }
    }
}

/// 配置读写与同步：不用 App Group 共享容器——自签名/ad-hoc 签名无真实 Team ID，
/// macOS 15+ 无法校验成员资格，主 App 一碰共享容器就弹 TCC“想访问其他 App 的数据”。
/// 改为：配置以 JSON 字符串放分布式通知的 object 广播（沙箱进程不能带 userInfo，
/// 但 object 字符串允许）；两侧各自落盘到自己的目录（主 App 真实 Application Support，
/// 扩展解析到自身沙箱容器作为冷启动缓存），全程无跨容器文件访问
enum RightClickConfigStore {

    static let didChangeNotification = "com.qoder.menutools.rightclick.configChanged"
    static let requestNotification = "com.qoder.menutools.rightclick.requestConfig"

    static var fileURL: URL {
        // homeDirectoryForCurrentUser：主 App（非沙箱）→ 真实用户目录；扩展（沙箱）→ 自身容器
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MenuTools", isDirectory: true)
            .appendingPathComponent("rightclick.json", isDirectory: false)
    }

    static func load() -> RightClickConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(RightClickConfig.self, from: data) else {
            return .default
        }
        // 合并新增项的缺省值，兼容旧配置
        var merged = config
        for item in RightClickItem.allCases where merged.enabled[item.rawValue] == nil {
            merged.enabled[item.rawValue] = true
        }
        return merged
    }

    /// 仅写盘（扩展缓存广播来的配置时也用）
    static func persist(_ config: RightClickConfig) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: fileURL)
    }

    /// 主 App 侧：保存并广播给扩展
    static func save(_ config: RightClickConfig) {
        persist(config)
        broadcast(config)
    }

    /// 配置以 JSON 字符串放通知 object 广播
    static func broadcast(_ config: RightClickConfig) {
        guard let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(didChangeNotification), object: json, deliverImmediately: true
        )
    }

    static func decode(_ object: String?) -> RightClickConfig? {
        guard let object, let data = object.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RightClickConfig.self, from: data)
    }
}

/// 扩展 → 主 App 的操作指令：沙箱扩展没有任意目录写权限（新建文件/文件夹），
/// 也无法携带目录打开其它 App（在终端打开），转交非沙箱的常驻主 App 执行。
/// 指令同样以 JSON 字符串走通知 object，不落盘
struct RightClickCommand: Codable {
    var action: String      // RightClickItem.rawValue
    var paths: [String]     // 作用路径
    var fileExtension: String? = nil  // 新建文件的扩展名（txt/md/json 等）
}

enum RightClickCommandStore {

    static let commandNotification = "com.qoder.menutools.rightclick.command"

    /// 扩展侧：指令序列化后经通知 object 发给主 App
    static func send(_ command: RightClickCommand) {
        guard let data = try? JSONEncoder().encode(command),
              let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(commandNotification), object: json, deliverImmediately: true
        )
    }

    /// 主 App 侧：从通知 object 解码指令
    static func decode(_ object: String?) -> RightClickCommand? {
        guard let object, let data = object.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RightClickCommand.self, from: data)
    }
}
