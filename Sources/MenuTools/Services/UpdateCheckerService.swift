import AppKit
import Foundation

private func normalizedUpdateVersion(_ raw: String) -> String {
    var version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if version.first == "v" || version.first == "V" {
        version.removeFirst()
    }
    if let buildIndex = version.firstIndex(of: "+") {
        version = String(version[..<buildIndex])
    }
    return version
}

/// 一次可用更新的信息
struct UpdateInfo: Codable, Equatable {
    let version: String
    let notes: String?
    let url: String?
}

/// 检查 App 自身版本更新
/// 默认对接 GitHub Releases API（发布 Release 即生效）；
/// 也兼容简单 appcast JSON（{"version","notes","url"}），便于私有部署与本地测试
@MainActor
enum UpdateCheckerService {

    /// 更新源地址；可通过 `defaults write com.qoder.menutools updateFeedURL <url>` 覆盖
    static let feedURLKey = "updateFeedURL"
    static let defaultFeedURL = "https://api.github.com/repos/Monkey0803/MenuTools/releases/latest"

    /// 自动检查节流：最近一次检查时间
    static let lastCheckKey = "lastUpdateCheckDate"
    static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    enum UpdateError: LocalizedError {
        case invalidFeedURL
        case badResponse

        var errorDescription: String? {
            switch self {
            case .invalidFeedURL: return L("error.feedInvalid")
            case .badResponse: return L("error.feedBad")
            }
        }
    }

    /// GitHub Releases API 响应（仅取所需字段）
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
        }
        let tagName: String
        let body: String?
        let htmlUrl: String
        let assets: [Asset]
    }

    /// 当前运行中的版本号（来自 Info.plist）
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// 检查更新；返回 nil 表示已是最新（含仓库尚未发布任何 Release 的情况）
    static func check() async throws -> UpdateInfo? {
        let urlString = UserDefaults.standard.string(forKey: feedURLKey) ?? defaultFeedURL
        guard let url = URL(string: urlString) else { throw UpdateError.invalidFeedURL }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse {
            // 404 = 仓库还没有发布任何 Release，视为已是最新
            if http.statusCode == 404 { return recordCheckAndReturn(nil) }
            guard (200...299).contains(http.statusCode) else { throw UpdateError.badResponse }
        }

        let info = try parse(data)
        let isNew = isVersion(info.version, newerThan: currentVersion)
        return recordCheckAndReturn(isNew ? info : nil)
    }

    /// 距上次检查超过间隔才触发的静默自动检查
    static func shouldAutoCheck() -> Bool {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        return Date().timeIntervalSince1970 - last > autoCheckInterval
    }

    /// 打开新版本的下载页面
    static func openDownloadPage(_ info: UpdateInfo) {
        guard let urlString = info.url, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 内部实现

    /// 优先按 GitHub Release 解析，失败则回退到 appcast 格式
    static func parse(_ data: Data) throws -> UpdateInfo {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let release = try? decoder.decode(GitHubRelease.self, from: data) {
            // 优先直链安装包资产，否则跳转 Release 页面
            let asset = release.assets.first {
                $0.name.hasSuffix(".dmg") || $0.name.hasSuffix(".zip") || $0.name.hasSuffix(".pkg")
            }
            return UpdateInfo(
                version: normalizedVersion(release.tagName),
                notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines),
                url: asset?.browserDownloadUrl ?? release.htmlUrl
            )
        }
        let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
        return UpdateInfo(
            version: normalizedVersion(info.version),
            notes: info.notes,
            url: info.url
        )
    }

    private static func recordCheckAndReturn(_ info: UpdateInfo?) -> UpdateInfo? {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        return info
    }

    /// 规范化版本号，兼容 v1.2.0 和 1.2.0+build.1。
    static func normalizedVersion(_ raw: String) -> String {
        normalizedUpdateVersion(raw)
    }

    /// 按 SemVer 规则比较版本，支持预发布标识符和 build metadata。
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let candidate = SemanticVersion(candidate),
              let current = SemanticVersion(current) else { return false }
        return candidate > current
    }

    private struct SemanticVersion: Comparable {
        private enum Identifier {
            case numeric(Int)
            case text(String)
        }

        let numbers: [Int]
        private let prerelease: [Identifier]

        init?(_ raw: String) {
            let normalized = normalizedUpdateVersion(raw)
            let parts = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let core = parts.first, !core.isEmpty else { return nil }

            let numberStrings = core.split(separator: ".", omittingEmptySubsequences: false)
            guard !numberStrings.isEmpty,
                  numberStrings.allSatisfy({ Int($0) != nil }) else { return nil }
            numbers = numberStrings.map { Int($0)! }

            if parts.count == 1 {
                prerelease = []
            } else {
                let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
                guard !identifiers.isEmpty, !identifiers.contains(where: { $0.isEmpty }) else { return nil }
                prerelease = identifiers.map { identifier in
                    if let number = Int(identifier) {
                        return .numeric(number)
                    }
                    return .text(String(identifier))
                }
            }
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            compare(lhs, rhs) == 0
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            compare(lhs, rhs) < 0
        }

        private static func compare(_ lhs: Self, _ rhs: Self) -> Int {
            for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
                let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
                let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
                if left != right { return left < right ? -1 : 1 }
            }

            if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
                return lhs.prerelease.isEmpty ? 1 : -1
            }

            for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
                guard index < lhs.prerelease.count else { return -1 }
                guard index < rhs.prerelease.count else { return 1 }
                switch (lhs.prerelease[index], rhs.prerelease[index]) {
                case let (.numeric(left), .numeric(right)):
                    if left != right { return left < right ? -1 : 1 }
                case (.numeric, .text):
                    return -1
                case (.text, .numeric):
                    return 1
                case let (.text(left), .text(right)):
                    if left != right { return left < right ? -1 : 1 }
                }
            }
            return 0
        }
    }
}
