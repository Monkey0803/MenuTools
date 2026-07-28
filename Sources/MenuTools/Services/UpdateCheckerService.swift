import AppKit
import Foundation

/// 远程更新源的 JSON 结构（appcast）
/// 示例：{ "version": "1.1.0", "notes": "新增夜览开关", "url": "https://example.com/MenuTools.dmg" }
struct UpdateInfo: Codable, Equatable {
    let version: String
    let notes: String?
    let url: String?
}

/// 检查 App 自身版本更新
@MainActor
enum UpdateCheckerService {

    /// 更新源地址；可通过 `defaults write com.qoder.menutools updateFeedURL <url>` 覆盖，便于测试与私有部署
    static let feedURLKey = "updateFeedURL"
    static let defaultFeedURL = "https://raw.githubusercontent.com/qoder/MenuTools/main/appcast.json"

    enum UpdateError: LocalizedError {
        case invalidFeedURL
        case badResponse

        var errorDescription: String? {
            switch self {
            case .invalidFeedURL: return "更新源地址无效"
            case .badResponse: return "更新源返回异常"
            }
        }
    }

    /// 当前运行中的版本号（来自 Info.plist）
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// 检查更新；返回 nil 表示已是最新
    static func check() async throws -> UpdateInfo? {
        let urlString = UserDefaults.standard.string(forKey: feedURLKey) ?? defaultFeedURL
        guard let url = URL(string: urlString) else { throw UpdateError.invalidFeedURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.badResponse
        }
        let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
        return isVersion(info.version, newerThan: currentVersion) ? info : nil
    }

    /// 打开新版本的下载页面
    static func openDownloadPage(_ info: UpdateInfo) {
        guard let urlString = info.url, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 语义化版本比较：按 "." 分段逐位比较数字，缺位补 0
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
