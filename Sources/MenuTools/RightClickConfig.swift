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
struct RightClickConfig: Codable, Equatable {
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

/// 配置读写：固定路径，App 写、扩展读，写入后发跨进程通知让扩展即时刷新
enum RightClickConfigStore {

    static let didChangeNotification = "com.qoder.menutools.rightclick.configChanged"
    static let appGroup = "group.com.qoder.menutools"

    static var fileURL: URL {
        // 优先用 App Group 共享容器（沙箱扩展与主 App 都能访问）
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return container.appendingPathComponent("rightclick.json", isDirectory: false)
        }
        // 回退：主 App 非沙箱时可用（扩展沙箱下读不到，仅保底）
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MenuTools", isDirectory: true)
        return dir.appendingPathComponent("rightclick.json", isDirectory: false)
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

    static func save(_ config: RightClickConfig) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: fileURL)
        // 通知扩展进程刷新
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(didChangeNotification), object: nil, deliverImmediately: true
        )
    }
}
