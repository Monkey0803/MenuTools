import AppKit
import Foundation

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
    private static func parse(_ data: Data) throws -> UpdateInfo {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let release = try? decoder.decode(GitHubRelease.self, from: data) {
            // tag 允许带 v 前缀（v1.2.0 / 1.2.0）
            let version = release.tagName.hasPrefix("v") || release.tagName.hasPrefix("V")
                ? String(release.tagName.dropFirst())
                : release.tagName
            // 优先直链安装包资产，否则跳转 Release 页面
            let asset = release.assets.first {
                $0.name.hasSuffix(".dmg") || $0.name.hasSuffix(".zip") || $0.name.hasSuffix(".pkg")
            }
            return UpdateInfo(
                version: version,
                notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines),
                url: asset?.browserDownloadUrl ?? release.htmlUrl
            )
        }
        return try JSONDecoder().decode(UpdateInfo.self, from: data)
    }

    private static func recordCheckAndReturn(_ info: UpdateInfo?) -> UpdateInfo? {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        return info
    }

    /// 语义化版本比较：按 "." 分段逐位比较数字，缺位补 0
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0.trimmingCharacters(in: .letters)) ?? 0 }
        let b = current.split(separator: ".").map { Int($0.trimmingCharacters(in: .letters)) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
