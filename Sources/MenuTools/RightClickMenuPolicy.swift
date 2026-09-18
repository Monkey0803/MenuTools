import Foundation

struct RightClickSelection: Equatable, Sendable {
    var path: String
    var isDirectory: Bool
}

enum RightClickClipboardKind: Equatable, Sendable {
    case none
    case text
    case image
}

struct RightClickMenuContext: Equatable, Sendable {
    var directoryPath: String?
    var selection: [RightClickSelection]
    var clipboard: RightClickClipboardKind
}

enum RightClickMenuEntry: Equatable, Sendable {
    case action(RightClickItem)
    case copy([RightClickItem])
}

/// 菜单可见性只取决于快照，不在构建菜单期间访问文件系统。
enum RightClickMenuPolicy {
    /// 复制组放在首个可见复制项的位置，其子项继续遵循用户排序与开关。
    static func entries(config: RightClickConfig, context: RightClickMenuContext) -> [RightClickMenuEntry] {
        let visible = visibleItems(config: config, context: context)
        let copies = visible.filter { $0.group == .copy }
        var insertedCopy = false
        return visible.compactMap { item in
            guard item.group == .copy else { return .action(item) }
            guard !insertedCopy else { return nil }
            insertedCopy = true
            return .copy(copies)
        }
    }

    /// targetedURL 在项目菜单中可能指向选中项；浏览基准必须与新建目标目录分开。
    static func browsingDirectory(target: RightClickSelection?, selection: [RightClickSelection], isContainer: Bool) -> String? {
        guard let target else { return nil }
        if isContainer { return target.path }
        if selection.contains(where: { $0.path == target.path }) || !target.isDirectory {
            return (target.path as NSString).deletingLastPathComponent
        }
        return target.path
    }

    static func visibleItems(config: RightClickConfig, context: RightClickMenuContext) -> [RightClickItem] {
        let selection = context.selection
        let hasSelection = !selection.isEmpty
        let hasTarget = !affectedPaths(context: context).isEmpty
        let canCreate = targetDirectory(context: context) != nil
            && (selection.isEmpty || (selection.count == 1 && selection[0].isDirectory))
        let filesOnly = hasSelection && selection.allSatisfy { !$0.isDirectory }
        return config.enabledItems.filter { item in
            switch item {
            case .newFolder: return canCreate
            case .newFile: return canCreate && !config.templates.isEmpty
            case .saveClipboard: return canCreate && context.clipboard != .none
            case .openInTerminal: return selection.count <= 1 && targetDirectory(context: context) != nil
            case .openWithApp: return hasTarget && !applications(config.applications, context: context).isEmpty
            case .copyToFolder, .moveToFolder: return hasSelection && !config.destinations.isEmpty
            case .undoLastOperation: return hasTarget
            case .batchRename: return filesOnly
            case .copyFileContents: return selection.count == 1 && filesOnly
            case .copyFileInfo: return filesOnly
            case .copyDirectoryListing: return selection.count == 1 && selection[0].isDirectory
            case .checksum: return filesOnly
            case .verifyChecksum: return filesOnly && selection.count == 1
            case .copyCurrentRelativePath: return hasSelection && !(context.directoryPath?.isEmpty ?? true)
            case .copyGitRelativePath: return hasSelection
            case .copyFilename, .copyFilenameWithoutExtension, .copyAbsolutePath, .copyRelativePath,
                 .copyEscapedPath, .copyFileURL, .copyMarkdownLink:
                return hasTarget
            }
        }
    }

    static func applications(_ applications: [RightClickApplication], context: RightClickMenuContext) -> [RightClickApplication] {
        let affected = context.selection.isEmpty
            ? affectedPaths(context: context).map { RightClickSelection(path: $0, isDirectory: true) }
            : context.selection
        return applications.filter { application in
            affected.allSatisfy { application.filter.matches(path: $0.path, isDirectory: $0.isDirectory) }
        }
    }

    /// 单文件对应父目录；单目录对应其自身；多选不推测创建目标。
    static func targetDirectory(context: RightClickMenuContext) -> String? {
        if context.selection.count == 1, let selected = context.selection.first {
            guard !selected.path.isEmpty else { return nil }
            return selected.isDirectory ? selected.path : (selected.path as NSString).deletingLastPathComponent
        }
        guard context.selection.isEmpty, let directory = context.directoryPath, !directory.isEmpty else { return nil }
        return directory
    }

    static func affectedPaths(context: RightClickMenuContext) -> [String] {
        if !context.selection.isEmpty { return context.selection.map(\.path) }
        guard let directory = context.directoryPath, !directory.isEmpty else { return [] }
        return [directory]
    }
}

/// 纯字符串路径格式化，保留 Unicode 且不执行符号链接解析或磁盘探测。
enum RightClickPathFormatter {
    static func relativePath(path: String, base: String) -> String {
        guard path.hasPrefix("/"), base.hasPrefix("/") else { return path }
        let target = components(path)
        let origin = components(base)
        let common = zip(target, origin).prefix { $0 == $1 }.count
        let result = Array(repeating: "..", count: origin.count - common) + target.dropFirst(common)
        return result.isEmpty ? "." : result.joined(separator: "/")
    }

    static func homeRelativePath(path: String, home: String) -> String {
        guard path.hasPrefix("/"), home.hasPrefix("/") else { return path }
        let target = components(path)
        let origin = components(home)
        guard target.starts(with: origin) else { return path }
        let remaining = target.dropFirst(origin.count)
        return remaining.isEmpty ? "~" : "~/" + remaining.joined(separator: "/")
    }

    static func shellEscaped(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func markdownLink(path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        let label = filename.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let destination = URL(fileURLWithPath: path).absoluteString
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        return "[\(label)](\(destination))"
    }

    static func filenameWithoutExtension(path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return filename }
        return String(filename[..<dot])
    }

    private static func components(_ path: String) -> [String] {
        var result: [String] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !result.isEmpty { result.removeLast() }
            default: result.append(String(component))
            }
        }
        return result
    }
}
