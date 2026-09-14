import Foundation

/// 单个版本的更新说明（来自打包进 App 的 `ReleaseNotes.md`）。
struct AppReleaseNote: Equatable, Sendable {
    var version: String
    /// 版本号后面的日期文本；没有写日期时为 nil。
    var dateText: String?
    var bullets: [String]
}

/// 解析并读取打包进 App 的更新说明。
///
/// 文件格式（`Resources/ReleaseNotes.md`）：
/// ```
/// # 更新说明
///
/// ## 1.1.1 — 2026-09-14
///
/// - 新增…
/// - 修复…
///
/// ## 1.1.0 — 2026-09-14
/// - …
/// ```
enum AppReleaseNotes {
    static let resourceName = "ReleaseNotes"

    /// 从 markdown 文本里取出指定版本的说明；找不到返回 nil。
    static func note(for version: String, in markdown: String) -> AppReleaseNote? {
        var current: (version: String, dateText: String?)?
        var collected: [String] = []

        func finish() -> AppReleaseNote? {
            guard let current, current.version == version else { return nil }
            return AppReleaseNote(version: current.version, dateText: current.dateText, bullets: collected)
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                // 遇到下一个标题：先结算上一段，命中目标版本就直接返回。
                if let result = finish() { return result }
                current = heading(from: String(line.dropFirst(3)))
                collected = []
                continue
            }
            guard current != nil else { continue }
            let bullet = bulletText(from: line)
            if !bullet.isEmpty { collected.append(bullet) }
        }
        return finish()
    }

    /// 读取打包进 App 的更新说明。
    static func note(for version: String, bundle: Bundle = .main) -> AppReleaseNote? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return note(for: version, in: markdown)
    }

    /// 当前版本的更新说明。
    static func current(bundle: Bundle = .main) -> AppReleaseNote? {
        note(for: AppVersionService.current, bundle: bundle)
    }

    // MARK: - 解析细节

    /// 解析 `## ` 之后的内容，形如 `1.1.1 — 2026-09-14` / `1.1.1 - 2026-09-14` / `1.1.1`。
    private static func heading(from text: String) -> (version: String, dateText: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let separators = ["—", "–", "·", "|", "-"]
        for separator in separators {
            if let range = trimmed.range(of: separator) {
                let version = String(trimmed[trimmed.startIndex ..< range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let date = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !version.isEmpty else { return nil }
                return (version, date.isEmpty ? nil : date)
            }
        }
        return (trimmed, nil)
    }

    private static func bulletText(from line: String) -> String {
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        // 段落里的普通说明行也保留（例如「首个公开版本」）。
        return line.hasPrefix("#") ? "" : line
    }
}
