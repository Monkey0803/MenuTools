import Foundation

enum RightClickFileKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case text, code, image, pdf, audio, video, archive, directory, other
    var id: String { rawValue }
    var titleKey: String { "rc.fileKind.\(rawValue)" }
}

struct RightClickApplicationFilter: Codable, Equatable, Sendable {
    var kinds: Set<RightClickFileKind>
    static let all = RightClickApplicationFilter(kinds: Set(RightClickFileKind.allCases))

    func matches(path: String, isDirectory: Bool) -> Bool {
        kinds.contains(Self.kind(path: path, isDirectory: isDirectory))
    }

    private static func kind(path: String, isDirectory: Bool) -> RightClickFileKind {
        if isDirectory { return .directory }
        let ext = (path as NSString).pathExtension.lowercased()
        if codeExtensions.contains(ext) { return .code }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if archiveExtensions.contains(ext) { return .archive }
        if textExtensions.contains(ext) { return .text }
        return .other
    }

    private static let codeExtensions: Set<String> = [
        "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm", "swift", "java", "kt", "kts",
        "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "php", "sh", "zsh", "fish",
        "html", "css", "scss", "less", "vue", "svelte", "json", "yaml", "yml", "xml",
        "toml", "ini", "gradle", "sql"
    ]
    private static let textExtensions: Set<String> = ["txt", "md", "markdown", "rtf", "csv", "log"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "svg"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "pkg"]
}
