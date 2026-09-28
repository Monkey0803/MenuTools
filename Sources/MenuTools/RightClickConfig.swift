import Foundation

/// Finder 右键工具的配置项 Key（与菜单动作一一对应）。
enum RightClickItem: String, CaseIterable, Identifiable, Codable, Sendable {
    case newFolder
    case newFile
    case saveClipboard
    case openInTerminal
    case openWithApp
    case copyToFolder
    case moveToFolder
    case undoLastOperation
    case batchRename
    case copyFileContents
    case copyFileInfo
    case copyDirectoryListing
    case copyFilename
    case copyFilenameWithoutExtension
    case copyAbsolutePath
    case copyRelativePath
    case copyCurrentRelativePath
    case copyGitRelativePath
    case copyEscapedPath
    case copyFileURL
    case copyMarkdownLink
    case checksum
    case verifyChecksum

    var id: String { rawValue }
    var titleKey: String { "rc.item.\(rawValue)" }
    var subtitleKey: String? {
        switch self {
        case .newFile, .copyRelativePath, .copyCurrentRelativePath, .copyGitRelativePath, .copyEscapedPath:
            return "rc.item.\(rawValue).desc"
        default: return nil
        }
    }

    /// Finder 菜单项的 SF Symbol；名称都是系统自带符号，不随语言变化。
    var symbolName: String {
        switch self {
        case .newFolder: return "folder.badge.plus"
        case .newFile: return "doc.badge.plus"
        case .saveClipboard: return "doc.on.clipboard"
        case .openInTerminal: return "terminal"
        case .openWithApp: return "arrow.up.forward.app"
        case .copyToFolder: return "doc.on.doc"
        case .moveToFolder: return "arrow.right.square"
        case .undoLastOperation: return "arrow.uturn.backward"
        case .batchRename: return "textformat.abc"
        case .copyFileContents: return "doc.text"
        case .copyFileInfo: return "info.circle"
        case .copyDirectoryListing: return "list.bullet.indent"
        case .copyFilename: return "textformat"
        case .copyFilenameWithoutExtension: return "textformat.size"
        case .copyAbsolutePath: return "link"
        case .copyRelativePath: return "house"
        case .copyCurrentRelativePath: return "arrow.turn.down.right"
        case .copyGitRelativePath: return "arrow.triangle.branch"
        case .copyEscapedPath: return "curlybraces"
        case .copyFileURL: return "globe"
        case .copyMarkdownLink: return "doc.richtext"
        case .checksum: return "number"
        case .verifyChecksum: return "checkmark.shield"
        }
    }

    enum Group: String, CaseIterable, Identifiable, Sendable {
        case directory
        case copy
        case file
        var id: String { rawValue }
        var titleKey: String { "rc.group.\(rawValue)" }
        var symbolName: String {
            switch self {
            case .directory: return "folder"
            case .copy: return "doc.on.doc"
            case .file: return "doc"
            }
        }
    }

    var group: Group {
        switch self {
        case .newFolder, .newFile, .saveClipboard, .openInTerminal, .openWithApp: return .directory
        case .copyToFolder, .moveToFolder, .undoLastOperation, .batchRename, .checksum, .verifyChecksum: return .file
        case .copyFilename, .copyFilenameWithoutExtension, .copyAbsolutePath, .copyRelativePath,
             .copyCurrentRelativePath, .copyGitRelativePath, .copyEscapedPath, .copyFileURL, .copyMarkdownLink,
             .copyFileContents, .copyFileInfo, .copyDirectoryListing:
            return .copy
        }
    }
}

/// Finder 右键菜单的呈现方式：默认二级菜单、按行为分组，或直接平铺到 Finder 菜单。
enum RightClickMenuStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case nested
    case grouped
    case flat

    var id: String { rawValue }
    var titleKey: String { "rc.menuStyle.\(rawValue)" }
}

struct RightClickTemplate: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var filename: String
    var content: String

    static let builtIns: [RightClickTemplate] = [
        .init(id: "txt", name: ".txt", filename: "Untitled.txt", content: ""),
        .init(id: "md", name: ".md", filename: "Untitled.md", content: ""),
        .init(id: "json", name: ".json", filename: "Untitled.json", content: "{}\n"),
        .init(id: "yaml", name: ".yaml", filename: "Untitled.yaml", content: ""),
        .init(id: "xml", name: ".xml", filename: "Untitled.xml", content: ""),
        .init(id: "csv", name: ".csv", filename: "Untitled.csv", content: ""),
        .init(id: "html", name: ".html", filename: "Untitled.html", content: ""),
        .init(id: "css", name: ".css", filename: "Untitled.css", content: ""),
        .init(id: "js", name: ".js", filename: "Untitled.js", content: ""),
        .init(id: "py", name: ".py", filename: "Untitled.py", content: ""),
        .init(id: "sh", name: ".sh", filename: "Untitled.sh", content: ""),
        .init(id: "readme", name: "README.md", filename: "README.md", content: NSLocalizedString("rc.template.readmeContent", value: "# Project name\n\nProject description.\n", comment: "")),
        .init(id: "gitignore", name: ".gitignore", filename: ".gitignore", content: ".DS_Store\n.build/\n"),
        .init(id: "editorconfig", name: ".editorconfig", filename: ".editorconfig", content: "root = true\n\n[*]\ncharset = utf-8\nindent_style = space\nindent_size = 4\ninsert_final_newline = true\n")
    ]
}

struct RightClickApplication: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var path: String
    var bundleIdentifier: String
    var filter: RightClickApplicationFilter

    init(id: String, name: String, path: String, bundleIdentifier: String,
         filter: RightClickApplicationFilter = .all) {
        self.id = id
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.filter = filter
    }

    private enum CodingKeys: String, CodingKey { case id, name, path, bundleIdentifier, filter }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        filter = try container.decodeIfPresent(RightClickApplicationFilter.self, forKey: .filter) ?? .all
    }
}

struct RightClickDestination: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var path: String
}

struct RightClickDirectoryListingOptions: Codable, Equatable, Sendable {
    var includeHidden: Bool
    var maxDepth: Int
    var ignoredPatterns: [String]

    static let `default` = RightClickDirectoryListingOptions(
        includeHidden: false, maxDepth: 20, ignoredPatterns: [])
}

/// App 与 Finder 扩展共享的配置；缺少新字段时迁移旧版本配置。
/// 应用内语言 → lproj 目录名。
///
/// 主程序按 `appLanguage` 手动选 lproj，而 Finder 扩展此前用 `NSLocalizedString`，
/// 只按**系统**语言：非中文系统 + 手动切中文时会出现「主界面英文、右键菜单中文」。
/// 语言跟着共享配置走，扩展与本进程用的是同一套规则。
enum RightClickConfigLanguage {
    /// 与主程序 `SettingsKey.appLanguage` 同一个键。
    static let defaultsKey = "appLanguage"
    static let supported = ["en", "ja", "ko", "zh-Hans", "zh-Hant"]

    /// `system`、空值与未知取值都归一化为 nil（表示跟随系统）。
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return supported.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// 解析应当使用的 lproj：手动设置优先，其次按系统首选语言顺序匹配。
    static func resourceLanguage(configured: String?, preferredLanguages: [String]) -> String? {
        if let configured = normalized(configured) { return configured }
        for preferred in preferredLanguages {
            let normalized = preferred.lowercased()
            if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw")
                || normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-mo") {
                return "zh-Hant"
            }
            if normalized.hasPrefix("zh") { return "zh-Hans" }
            if normalized.hasPrefix("en") { return "en" }
            if normalized.hasPrefix("ja") { return "ja" }
            if normalized.hasPrefix("ko") { return "ko" }
        }
        return nil
    }

    private static let lock = NSLock()
    /// 只在 lock 保护下读写；菜单构建可能来自 Finder 的 XPC 线程。
    nonisolated(unsafe) private static var bundleCache: [String: Bundle] = [:]

    /// 取对应语言的资源 bundle；解析不到时回退主 bundle。
    ///
    /// 菜单构建可能来自 Finder 的 XPC 线程，缓存必须加锁。
    static func localizedBundle(for language: String?, in bundle: Bundle = .main) -> Bundle {
        guard let resource = resourceLanguage(
            configured: language,
            preferredLanguages: Locale.preferredLanguages
        ), let path = bundle.path(forResource: resource, ofType: "lproj"),
           let localized = Bundle(path: path) else { return bundle }

        lock.lock()
        defer { lock.unlock() }
        if let cached = bundleCache[resource] { return cached }
        bundleCache[resource] = localized
        return localized
    }
}

struct RightClickConfig: Codable, Equatable, Sendable {
    var enabled: [String: Bool]
    var order: [String]
    var templates: [RightClickTemplate]
    var applications: [RightClickApplication]
    var destinations: [RightClickDestination]
    var directoryListing: RightClickDirectoryListingOptions
    var menuStyle: RightClickMenuStyle
    /// 操作日志开关。放在共享配置里，沙盒扩展才读得到（它读不到主 App 的 UserDefaults）。
    var loggerEnabled: Bool
    /// 应用内语言（lproj 名）；nil 表示跟随系统。扩展据此选资源，
    /// 避免出现「主界面英文、右键菜单中文」。
    var language: String? = nil

    init(
        enabled: [String: Bool], order: [String] = [],
        templates: [RightClickTemplate] = RightClickTemplate.builtIns,
        applications: [RightClickApplication] = [], destinations: [RightClickDestination] = [],
        directoryListing: RightClickDirectoryListingOptions = .default,
        menuStyle: RightClickMenuStyle = .nested,
        loggerEnabled: Bool = false
    ) {
        self.enabled = enabled
        self.order = order
        self.templates = templates
        self.applications = applications
        self.destinations = destinations
        self.directoryListing = directoryListing
        self.menuStyle = menuStyle
        self.loggerEnabled = loggerEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, order, templates, applications, destinations, directoryListing, menuStyle, loggerEnabled, language
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode([String: Bool].self, forKey: .enabled)
        // 明确区分缺字段与错误的 null，避免损坏数据悄悄覆盖用户设置。
        order = try container.contains(.order) ? container.decode([String].self, forKey: .order) : []
        templates = try container.contains(.templates) ? container.decode([RightClickTemplate].self, forKey: .templates) : RightClickTemplate.builtIns
        applications = try container.contains(.applications) ? container.decode([RightClickApplication].self, forKey: .applications) : []
        destinations = try container.contains(.destinations) ? container.decode([RightClickDestination].self, forKey: .destinations) : []
        directoryListing = try container.contains(.directoryListing)
            ? container.decode(RightClickDirectoryListingOptions.self, forKey: .directoryListing) : .default
        menuStyle = try container.contains(.menuStyle)
            ? container.decode(RightClickMenuStyle.self, forKey: .menuStyle) : .nested
        loggerEnabled = try container.contains(.loggerEnabled)
            ? container.decode(Bool.self, forKey: .loggerEnabled) : false
        language = try container.decodeIfPresent(String.self, forKey: .language)
    }

    static let `default` = RightClickConfig(
        enabled: Dictionary(uniqueKeysWithValues: RightClickItem.allCases.map { ($0.rawValue, true) })
    )
    static let disabled = RightClickConfig(
        enabled: Dictionary(uniqueKeysWithValues: RightClickItem.allCases.map { ($0.rawValue, false) })
    )

    func isEnabled(_ item: RightClickItem) -> Bool { enabled[item.rawValue] ?? true }

    /// 忽略过时项和重复项，保留用户顺序并补齐版本升级新增项。
    var orderedItems: [RightClickItem] {
        var seen: Set<RightClickItem> = []
        return (order.compactMap(RightClickItem.init(rawValue:)) + RightClickItem.allCases)
            .filter { seen.insert($0).inserted }
    }

    var enabledItems: [RightClickItem] { orderedItems.filter { isEnabled($0) } }

    /// 磁盘缓存的逐项降级：丢弃单个损坏条目，保留其余用户设置。
    ///
    /// 旧实现遇到任何一个非法条目就整体回退 `.default`，一个写错的模板会连带丢掉所有
    /// 应用、目录和排序；这里改为按条目过滤，并把越界数值夹取回可用范围。
    func sanitized() -> RightClickConfig {
        var result = self
        result.language = RightClickConfigLanguage.normalized(language)
        result.enabled = enabled.filter { RightClickItem(rawValue: $0.key) != nil }
        for item in RightClickItem.allCases where result.enabled[item.rawValue] == nil {
            result.enabled[item.rawValue] = true
        }
        result.order = order.filter { RightClickItem(rawValue: $0) != nil }
        result.templates = Self.sanitizeTemplates(templates)
        result.applications = Self.sanitize(applications, limit: 32,
                                            isValid: Self.applicationIsValid, id: \.id)
        result.destinations = Self.sanitize(destinations, limit: 32,
                                            isValid: Self.destinationIsValid, id: \.id)
        result.directoryListing = Self.sanitizeListing(directoryListing)
        return result
    }

    private static func sanitizeTemplates(_ templates: [RightClickTemplate]) -> [RightClickTemplate] {
        var totalContentBytes = 0
        return sanitize(templates, limit: 128, isValid: templateIsValid, id: \.id).filter { template in
            let bytes = template.content.utf8.count
            guard totalContentBytes + bytes <= 262_144 else { return false }
            totalContentBytes += bytes
            return true
        }
    }

    private static func sanitize<T>(_ items: [T], limit: Int,
                                    isValid: (T) -> Bool, id: (T) -> String) -> [T] {
        var seen: Set<String> = []
        var result: [T] = []
        for item in items where result.count < limit {
            let identifier = id(item)
            guard idIsValid(identifier), seen.insert(identifier).inserted, isValid(item) else { continue }
            result.append(item)
        }
        return result
    }

    private static func sanitizeListing(_ options: RightClickDirectoryListingOptions)
        -> RightClickDirectoryListingOptions {
        var result = options
        result.maxDepth = min(max(result.maxDepth, 0), 50)
        var totalBytes = 0
        var patterns: [String] = []
        for pattern in result.ignoredPatterns where patterns.count < 32 {
            guard !pattern.isEmpty, pattern.utf8.count <= 128, !containsControl(pattern),
                  totalBytes + pattern.utf8.count <= 4_096 else { continue }
            totalBytes += pattern.utf8.count
            patterns.append(pattern)
        }
        result.ignoredPatterns = patterns
        return result
    }

    private static func templateIsValid(_ template: RightClickTemplate) -> Bool {
        (try? validateName(template.name, limit: 128, field: "rc.config.field.templateName")) != nil
            && (try? validateName(template.filename, limit: 255, field: "rc.config.field.filename")) != nil
            && !filenameContainsDisallowedColon(template.filename)
            && template.content.utf8.count <= 32_768
    }

    private static func applicationIsValid(_ application: RightClickApplication) -> Bool {
        (try? validateName(application.name, limit: 128, field: "rc.config.field.applicationName")) != nil
            && isAbsolutePath(application.path) && application.path.lowercased().hasSuffix(".app")
            && application.bundleIdentifier.utf8.count <= 255
            && !containsControl(application.bundleIdentifier)
    }

    private static func destinationIsValid(_ destination: RightClickDestination) -> Bool {
        (try? validateName(destination.name, limit: 128, field: "rc.config.field.destinationName")) != nil
            && isAbsolutePath(destination.path)
    }

    private static func idIsValid(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && id.utf8.count <= 128 && !containsControl(id)
    }

    func validated() throws -> RightClickConfig {
        for key in enabled.keys.sorted() where RightClickItem(rawValue: key) == nil {
            throw RightClickConfigValidationError.unknownItem(key)
        }
        guard order.count <= 128 else { throw RightClickConfigValidationError.tooManyEntries("rc.config.field.order") }
        for key in order where RightClickItem(rawValue: key) == nil {
            throw RightClickConfigValidationError.unknownItem(key)
        }
        guard templates.count <= 128 else { throw RightClickConfigValidationError.tooManyEntries("rc.config.field.templates") }
        guard applications.count <= 32 else { throw RightClickConfigValidationError.tooManyEntries("rc.config.field.applications") }
        guard destinations.count <= 32 else { throw RightClickConfigValidationError.tooManyEntries("rc.config.field.destinations") }
        guard (0...50).contains(directoryListing.maxDepth), directoryListing.ignoredPatterns.count <= 32,
              directoryListing.ignoredPatterns.allSatisfy({ pattern in
                  !pattern.isEmpty && pattern.utf8.count <= 128 && !Self.containsControl(pattern)
              }), directoryListing.ignoredPatterns.reduce(0, { $0 + $1.utf8.count }) <= 4_096 else {
            throw RightClickConfigValidationError.invalidField("rc.config.field.directoryListing")
        }
        try Self.validateIDs(templates.map(\.id))
        try Self.validateIDs(applications.map(\.id))
        try Self.validateIDs(destinations.map(\.id))
        var totalContentBytes = 0
        for template in templates {
            try Self.validateName(template.name, limit: 128, field: "rc.config.field.templateName")
            try Self.validateName(template.filename, limit: 255, field: "rc.config.field.filename")
            guard !Self.filenameContainsDisallowedColon(template.filename) else {
                throw RightClickConfigValidationError.invalidField("rc.config.field.filename")
            }
            let bytes = template.content.utf8.count
            guard bytes <= 32_768 else { throw RightClickConfigValidationError.templateContentTooLarge }
            totalContentBytes += bytes
        }
        guard totalContentBytes <= 262_144 else { throw RightClickConfigValidationError.templateContentTooLarge }
        for app in applications {
            try Self.validateName(app.name, limit: 128, field: "rc.config.field.applicationName")
            guard Self.isAbsolutePath(app.path), app.path.lowercased().hasSuffix(".app") else {
                throw RightClickConfigValidationError.invalidField("rc.config.field.applicationPath")
            }
            guard app.bundleIdentifier.utf8.count <= 255, !Self.containsControl(app.bundleIdentifier) else {
                throw RightClickConfigValidationError.invalidField("rc.config.field.bundleIdentifier")
            }
        }
        for destination in destinations {
            try Self.validateName(destination.name, limit: 128, field: "rc.config.field.destinationName")
            guard Self.isAbsolutePath(destination.path) else {
                throw RightClickConfigValidationError.invalidField("rc.config.field.destinationPath")
            }
        }
        return self
    }

    private static func validateIDs(_ ids: [String]) throws {
        var seen: Set<String> = []
        for id in ids {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  id.utf8.count <= 128, !containsControl(id) else {
                throw RightClickConfigValidationError.invalidField("rc.config.field.identifier")
            }
            guard seen.insert(id).inserted else { throw RightClickConfigValidationError.duplicateID(id) }
        }
    }

    private static func validateName(_ name: String, limit: Int, field: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", name.utf8.count <= limit,
              !name.contains("/"), !name.contains("\\"), !containsControl(name) else {
            throw RightClickConfigValidationError.invalidField(field)
        }
    }

    private static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func filenameContainsDisallowedColon(_ filename: String) -> Bool {
        filename.replacingOccurrences(
            of: #"\{\{\s*prompt\s*:[^{}]+\}\}"#,
            with: "",
            options: .regularExpression
        ).contains(":")
    }

    private static func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4_096 && !containsControl(path)
            && !path.split(separator: "/").contains("..")
    }
}

enum RightClickConfigValidationError: Error, Equatable, Sendable, LocalizedError {
    case unknownItem(String)
    case tooManyEntries(String)
    case duplicateID(String)
    case invalidField(String)
    case templateContentTooLarge

    var errorDescription: String? { localizedDescription(in: .main) }

    /// 共享模型不能依赖主 App 的本地化工具；允许测试注入资源 Bundle。
    func localizedDescription(in bundle: Bundle) -> String {
        switch self {
        case .unknownItem(let item):
            let format = NSLocalizedString("rc.config.unknownItem", bundle: bundle, value: "Unknown menu item: %@", comment: "")
            return String(format: format, item)
        case .tooManyEntries(let field):
            let format = NSLocalizedString("rc.config.tooManyEntries", bundle: bundle, value: "Too many %@.", comment: "")
            return String(format: format, localizedField(field, in: bundle))
        case .duplicateID:
            return NSLocalizedString("rc.config.duplicateID", bundle: bundle, value: "The configuration contains duplicate identifiers.", comment: "")
        case .invalidField(let field):
            let format = NSLocalizedString("rc.config.invalidField", bundle: bundle, value: "%@ is invalid. Check the name and path.", comment: "")
            return String(format: format, localizedField(field, in: bundle))
        case .templateContentTooLarge:
            let format = NSLocalizedString("rc.config.templateContentTooLarge", bundle: bundle, value: "Template content is limited to %@ per template and %@ in total.", comment: "")
            return String(format: format, "32 KiB", "256 KiB")
        }
    }

    private func localizedField(_ key: String, in bundle: Bundle) -> String {
        let fallback: String
        switch key {
        case "rc.config.field.order": fallback = "Menu order"
        case "rc.config.field.templates": fallback = "Templates"
        case "rc.config.field.applications": fallback = "Applications"
        case "rc.config.field.destinations": fallback = "Destinations"
        case "rc.config.field.templateName": fallback = "Template name"
        case "rc.config.field.filename": fallback = "Filename"
        case "rc.config.field.applicationName": fallback = "Application name"
        case "rc.config.field.applicationPath": fallback = "Application path"
        case "rc.config.field.bundleIdentifier": fallback = "Application identifier"
        case "rc.config.field.destinationName": fallback = "Destination name"
        case "rc.config.field.destinationPath": fallback = "Destination path"
        case "rc.config.field.directoryListing": fallback = "Directory listing options"
        case "rc.config.field.identifier": fallback = "Identifier"
        default: fallback = key
        }
        return NSLocalizedString(key, bundle: bundle, value: fallback, comment: "")
    }
}

/// 右键配置的持久化边界，避免备份服务依赖具体文件系统实现。
protocol RightClickConfigPersisting: Sendable {
    func load() -> RightClickConfig
    func replace(_ config: RightClickConfig) throws
}

struct LocalRightClickConfigStore: RightClickConfigPersisting {
    func load() -> RightClickConfig { RightClickConfigStore.load() }
    func replace(_ config: RightClickConfig) throws { try RightClickConfigStore.replace(config) }
}

/// 配置通过分布式通知的 object 同步，两侧各自持久化冷启动缓存。
///
/// 位置按可用性降级，实测自签名/无 provisioning 的包即使带上 App Group entitlement，
/// 系统也会以 EPERM 拒绝写入共享容器，所以不能只按 entitlement 是否存在来选择路径：
/// 1. App Group 共享容器（Developer ID / App Store 签名且 provisioning 含该组时可用）；
/// 2. 当前进程自己的 Application Support —— 主 App 得到 `~/Library/Application Support`，
///    沙箱 Finder 扩展得到自己的容器目录，因此扩展同样能持久化冷启动缓存。
enum RightClickConfigStore {
    static let appGroupIdentifier = "group.com.qoder.menutools"
    static let didChangeNotification = "com.qoder.menutools.rightclick.configChanged"
    static let requestNotification = "com.qoder.menutools.rightclick.requestConfig"
    private static let probeName = ".menutools-write-probe"

    /// App Group 容器根目录；未授权时返回 nil。
    static func containerDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// 纯路径计算，便于在无签名的测试进程里验证容器选择与回退。
    static func configFileURL(inBaseDirectory base: URL) -> URL {
        base.appendingPathComponent("MenuTools", isDirectory: true)
            .appendingPathComponent("rightclick.json", isDirectory: false)
    }

    /// 真正写一次探针文件来判断目录可用；只看 entitlement 会被系统的 EPERM 骗过。
    static func isWritableDirectory(_ base: URL, fileManager: FileManager = .default) -> Bool {
        let directory = base.appendingPathComponent("MenuTools", isDirectory: true)
        let probe = directory.appendingPathComponent(probeName)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: probe, options: .atomic)
            try? fileManager.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// 按顺序取第一个真正可写的候选目录。
    static func writableBaseDirectory(candidates: [URL],
                                      fileManager: FileManager = .default) -> URL? {
        candidates.first { isWritableDirectory($0, fileManager: fileManager) }
    }

    static func resolveBaseDirectory(fileManager: FileManager = .default) -> URL {
        var candidates: [URL] = []
        if let container = containerDirectory(fileManager: fileManager) { candidates.append(container) }
        if let local = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(local)
        }
        return writableBaseDirectory(candidates: candidates, fileManager: fileManager)
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// 每个进程只探测一次；配置路径在进程生命周期内不会改变。
    private static let resolvedFileURL = configFileURL(inBaseDirectory: resolveBaseDirectory())

    static var fileURL: URL { resolvedFileURL }

    /// 旧版本把配置写在主 App 的 Application Support 下，迁移到当前可用位置一次即可。
    static func migrateLegacyConfig(to destination: URL, fileManager: FileManager = .default) {
        let legacy = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        migrateConfig(from: configFileURL(inBaseDirectory: legacy),
                      to: destination, fileManager: fileManager)
    }

    static func migrateConfig(from legacy: URL, to destination: URL,
                              fileManager: FileManager = .default) {
        guard legacy.path != destination.path,
              !fileManager.fileExists(atPath: destination.path),
              fileManager.fileExists(atPath: legacy.path),
              let data = try? Data(contentsOf: legacy) else { return }
        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: destination, options: .atomic)
    }

    /// 冷启动入口：先尝试迁移旧配置，再读取当前可用位置。
    static func load() -> RightClickConfig {
        let url = fileURL
        migrateLegacyConfig(to: url)
        return load(at: url)
    }

    static func load(at url: URL) -> RightClickConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(RightClickConfig.self, from: data) else { return .default }
        // 逐项降级：单个损坏条目不应让整份用户配置回退默认。
        return config.sanitized()
    }

    /// 扩展缓存写入失败时仍可使用当前内存配置。
    static func persist(_ config: RightClickConfig) { try? replace(config) }

    static func replace(_ config: RightClickConfig, at url: URL = fileURL) throws {
        let config = try config.validated()
        let data = try JSONEncoder().encode(config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// 主 App 必须先可靠落盘，再广播；失败由调用方呈现给用户。
    static func save(_ config: RightClickConfig, at url: URL = fileURL, notify: (RightClickConfig) -> Void = broadcast) throws {
        try replace(config, at: url)
        notify(config)
    }

    static func broadcast(_ config: RightClickConfig) {
        guard let validated = try? config.validated(),
              let data = try? JSONEncoder().encode(validated),
              let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(didChangeNotification), object: json, deliverImmediately: true
        )
    }

    static func decode(_ object: String?) -> RightClickConfig? {
        guard let object, let data = object.data(using: .utf8),
              let config = try? JSONDecoder().decode(RightClickConfig.self, from: data) else { return nil }
        return try? config.validated()
    }

    static func decode(_ notification: Notification) -> RightClickConfig? {
        decode(notification.object as? String)
    }
}

/// 将配置变更通知转换为视图状态，无法解码时保留当前配置。
enum RightClickConfigNotification {
    static func applying(_ notification: Notification, to current: RightClickConfig) -> RightClickConfig {
        RightClickConfigStore.decode(notification) ?? current
    }
}

/// 沙箱 Finder 扩展把写入和启动应用操作交给常驻主 App。
struct RightClickCommand: Codable, Equatable, Sendable {
    var action: String
    var paths: [String]
    var fileExtension: String? = nil
    var optionID: String? = nil
    var directoryPath: String? = nil
    var requestID: String? = nil
    /// 通道令牌：命令走 DistributedNotificationCenter，任何本地进程都能投递同名通知，
    /// 令牌用来证明这条命令确实来自我们的 Finder 扩展。
    var channelToken: String? = nil
}

/// 右键命令通道的共享令牌。
///
/// 命令通过 `DistributedNotificationCenter` 投递，通知名是公开的字符串，**任何本地进程**
/// 都能伪造一份 JSON 让主进程去执行文件操作（新建/改名/移动/复制），而主进程拿着用户的
/// 文件权限。这里放一个只有当前用户可读的令牌在载荷里，宿主校验通过才执行。
enum RightClickChannelSecret {
    static let fileName = "rightclick-channel.secret"
    /// 令牌长度（字节）；写成十六进制后字符数是它的两倍。
    static let tokenByteCount = 32

    /// 纯路径计算，便于在无签名的测试进程里验证。
    static func secretFileURL(inBaseDirectory base: URL) -> URL {
        base.appendingPathComponent("MenuTools", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func load(inBaseDirectory base: URL, fileManager: FileManager = .default) -> String? {
        guard let data = try? Data(contentsOf: secretFileURL(inBaseDirectory: base)),
              let token = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// 读取已有令牌，没有就生成一个并落盘（0600）。
    static func loadOrCreate(inBaseDirectory base: URL, fileManager: FileManager = .default) -> String? {
        if let existing = load(inBaseDirectory: base, fileManager: fileManager) { return existing }

        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        let url = secretFileURL(inBaseDirectory: base)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(token.utf8).write(to: url, options: .atomic)
            // 只有当前用户可读：令牌泄露等于把右键通道交出去。
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return token
        } catch {
            return nil
        }
    }

    /// 应用真实数据目录下的令牌（宿主与扩展共用同一份）。
    static func load(fileManager: FileManager = .default) -> String? {
        load(
            inBaseDirectory: RightClickConfigStore.resolveBaseDirectory(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    static func loadOrCreate(fileManager: FileManager = .default) -> String? {
        loadOrCreate(
            inBaseDirectory: RightClickConfigStore.resolveBaseDirectory(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    /// 常量时间比较，避免通过耗时差异逐字节猜令牌。
    static func matches(_ token: String?, expected: String) -> Bool {
        guard let token, !token.isEmpty, !expected.isEmpty else { return false }
        let candidate = Array(token.utf8)
        let reference = Array(expected.utf8)
        guard candidate.count == reference.count else { return false }
        var difference: UInt8 = 0
        for index in candidate.indices {
            difference |= candidate[index] ^ reference[index]
        }
        return difference == 0
    }
}

enum RightClickCommandStore {
    static let commandNotification = "com.qoder.menutools.rightclick.command"
    static let acceptedNotification = "com.qoder.menutools.rightclick.accepted"

    /// 给命令附加通道令牌。
    static func authenticated(_ command: RightClickCommand, secret: String) -> RightClickCommand {
        var copy = command
        copy.channelToken = secret
        return copy
    }

    /// 校验投递来源：令牌必须与宿主保存的一致，否则这条命令不是我们的扩展发出来的。
    static func isAuthentic(_ command: RightClickCommand, secret: String?) -> Bool {
        guard let secret else { return false }
        return RightClickChannelSecret.matches(command.channelToken, expected: secret)
    }

    static func send(_ command: RightClickCommand) {
        // 拿不到令牌就不发：宿主一定会拒收，发了也只是静默失败。
        guard let secret = RightClickChannelSecret.loadOrCreate() else { return }
        guard let data = try? JSONEncoder().encode(authenticated(command, secret: secret)),
              let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(commandNotification), object: json, deliverImmediately: true
        )
    }

    static func decode(_ object: String?) -> RightClickCommand? {
        guard let object, let data = object.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RightClickCommand.self, from: data)
    }
}
