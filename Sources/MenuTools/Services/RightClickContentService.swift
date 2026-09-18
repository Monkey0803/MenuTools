import AppKit
import Darwin
import Foundation
import ImageIO

enum RightClickFileContent: Equatable, Sendable {
    case text(String)
    case image(Data)
}

enum RightClickDirectoryListingStyle: String, Sendable { case list, tree, markdown, json }

enum RightClickContentError: LocalizedError, Equatable, Sendable {
    case contentTooLarge, imageTooLarge, contentUnsupported, listingLimitExceeded, listingDepthExceeded, invalidListingLimits
    var errorDescription: String? {
        switch self {
        case .contentTooLarge: return L("rc.error.contentTooLarge")
        case .imageTooLarge: return L("rc.error.imageTooLarge")
        case .contentUnsupported: return L("rc.error.contentUnsupported")
        case .listingLimitExceeded: return L("rc.error.listingLimitExceeded")
        case .listingDepthExceeded: return L("rc.error.listingDepthExceeded")
        case .invalidListingLimits: return L("rc.error.invalidListingLimits")
        }
    }
}

enum RightClickContentService {
    static func readFile(at url: URL, maxBytes: Int = 20 * 1024 * 1024,
                         maxImagePixels: Int = 40_000_000) throws -> RightClickFileContent {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw RightClickFileError.regularFileRequired
        }
        guard info.st_size <= maxBytes else { throw RightClickContentError.contentTooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            guard width > 0, height > 0, width <= maxImagePixels / max(height, 1) else {
                throw RightClickContentError.imageTooLarge
            }
            guard let bitmap = NSBitmapImageRep(data: data) else { throw RightClickContentError.contentUnsupported }
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw RightClickContentError.contentUnsupported
            }
            return .image(png)
        }
        let text: String?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { text = String(data: data.dropFirst(3), encoding: .utf8) }
        else if data.starts(with: [0xFF, 0xFE]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xFE, 0xFF]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else { text = String(data: data, encoding: .utf8) }
        guard let text else { throw RightClickContentError.contentUnsupported }
        let controls = text.unicodeScalars.filter {
            CharacterSet.controlCharacters.contains($0) && $0.value != 9 && $0.value != 10 && $0.value != 13
        }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }),
              controls.count <= max(1, text.unicodeScalars.count / 100) else {
            throw RightClickContentError.contentUnsupported
        }
        return .text(text)
    }

    static func directoryListing(at directory: URL, style: RightClickDirectoryListingStyle,
                                 options: RightClickDirectoryListingOptions = .default,
                                 maxEntries: Int = 10_000) throws -> String {
        guard maxEntries > 0, options.maxDepth >= 0 else { throw RightClickContentError.invalidListingLimits }
        try RightClickFileService.validateDirectory(directory)
        var count = 0
        func children(_ url: URL, relativeParent: String) throws -> [RightClickListingNode] {
            try Task.checkCancellation()
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [])
            return try urls.compactMap { child in
                let name = child.lastPathComponent
                if !options.includeHidden && name.hasPrefix(".") { return nil }
                let relativePath = relativeParent.isEmpty ? name : relativeParent + "/" + name
                if options.ignoredPatterns.contains(where: {
                    globMatches(pattern: $0, name: name, relativePath: relativePath)
                }) { return nil }
                let values = try child.resourceValues(forKeys: keys)
                return RightClickListingNode(
                    url: child, name: name, relativePath: relativePath,
                    isDirectory: values.isDirectory == true, isSymbolicLink: values.isSymbolicLink == true)
            }.sorted {
                let lhsDir = $0.isDirectory && !$0.isSymbolicLink
                let rhsDir = $1.isDirectory && !$1.isSymbolicLink
                if lhsDir != rhsDir { return lhsDir }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        func display(_ item: RightClickListingNode) -> String {
            item.name + (item.isSymbolicLink ? "@" : (item.isDirectory ? "/" : ""))
        }
        if style == .list {
            let items = try children(directory, relativeParent: "")
            guard items.count <= maxEntries else { throw RightClickContentError.listingLimitExceeded }
            return items.map(display).joined(separator: "\n")
        }

        func build(_ url: URL, relativeParent: String, depth: Int) throws -> [RightClickListingNode] {
            let items = try children(url, relativeParent: relativeParent)
            var result: [RightClickListingNode] = []
            for var item in items {
                try Task.checkCancellation()
                count += 1
                guard count <= maxEntries else { throw RightClickContentError.listingLimitExceeded }
                if item.isDirectory && !item.isSymbolicLink && depth < options.maxDepth {
                    item.children = try build(item.url, relativeParent: item.relativePath, depth: depth + 1)
                }
                result.append(item)
            }
            return result
        }
        let nodes = try build(directory, relativeParent: "", depth: 0)
        switch style {
        case .tree:
            var lines = [directory.lastPathComponent + "/"]
            func appendTree(_ items: [RightClickListingNode], prefix: String) {
                for (index, item) in items.enumerated() {
                    let last = index == items.count - 1
                    lines.append(prefix + (last ? "└── " : "├── ") + display(item))
                    appendTree(item.children, prefix: prefix + (last ? "    " : "│   "))
                }
            }
            appendTree(nodes, prefix: "")
            return lines.joined(separator: "\n")
        case .markdown:
            var lines = ["- \(directory.lastPathComponent)/"]
            func appendMarkdown(_ items: [RightClickListingNode], depth: Int) {
                for item in items {
                    lines.append(String(repeating: "  ", count: depth) + "- " + display(item))
                    appendMarkdown(item.children, depth: depth + 1)
                }
            }
            appendMarkdown(nodes, depth: 1)
            return lines.joined(separator: "\n")
        case .json:
            func object(_ node: RightClickListingNode) -> [String: Any] {
                var result: [String: Any] = [
                    "name": node.name,
                    "path": node.relativePath,
                    "type": node.isSymbolicLink ? "symlink" : (node.isDirectory ? "directory" : "file")
                ]
                if node.isDirectory && !node.isSymbolicLink { result["children"] = node.children.map(object) }
                return result
            }
            let root: [String: Any] = [
                "name": directory.lastPathComponent,
                "path": ".",
                "type": "directory",
                "children": nodes.map(object)
            ]
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        case .list:
            return ""
        }
    }

    private static func globMatches(pattern: String, name: String, relativePath: String) -> Bool {
        let characters = Array(pattern)
        var expression = "^"
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    expression += ".*"
                    index += 2
                    continue
                }
                expression += "[^/]*"
            } else if character == "?" {
                expression += "[^/]"
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        expression += "$"
        let value = pattern.contains("/") ? relativePath : name
        return value.range(of: expression, options: .regularExpression) != nil
    }
}

private struct RightClickListingNode {
    var url: URL
    var name: String
    var relativePath: String
    var isDirectory: Bool
    var isSymbolicLink: Bool
    var children: [RightClickListingNode] = []
}
