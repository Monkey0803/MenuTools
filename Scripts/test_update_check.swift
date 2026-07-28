#!/usr/bin/swift
// 验证更新检查逻辑（与 UpdateCheckerService 同款解析）：
// 1. GitHub Release 解析（Sparkle 仓库真实 API）
// 2. 本仓库 404（无 Release，应视为已最新）
// 3. appcast JSON 回退
import Foundation

struct UpdateInfo: Codable { let version: String; let notes: String?; let url: String? }
struct GitHubRelease: Decodable {
    struct Asset: Decodable { let name: String; let browserDownloadUrl: String }
    let tagName: String
    let body: String?
    let htmlUrl: String
    let assets: [Asset]
}

func parse(_ data: Data) throws -> UpdateInfo {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    if let release = try? decoder.decode(GitHubRelease.self, from: data) {
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        let asset = release.assets.first { $0.name.hasSuffix(".dmg") || $0.name.hasSuffix(".zip") || $0.name.hasSuffix(".pkg") }
        return UpdateInfo(version: version, notes: release.body, url: asset?.browserDownloadUrl ?? release.htmlUrl)
    }
    return try JSONDecoder().decode(UpdateInfo.self, from: data)
}

func isVersion(_ candidate: String, newerThan current: String) -> Bool {
    let a = candidate.split(separator: ".").map { Int($0.trimmingCharacters(in: .letters)) ?? 0 }
    let b = current.split(separator: ".").map { Int($0.trimmingCharacters(in: .letters)) ?? 0 }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

let semaphore = DispatchSemaphore(value: 0)

func fetch(_ urlString: String, done: @escaping (Data?, Int) -> Void) {
    var request = URLRequest(url: URL(string: urlString)!)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: request) { data, response, _ in
        done(data, (response as? HTTPURLResponse)?.statusCode ?? -1)
        semaphore.signal()
    }.resume()
    semaphore.wait()
}

// 1. GitHub Release 格式
fetch("https://api.github.com/repos/sparkle-project/Sparkle/releases/latest") { data, code in
    guard code == 200, let data, let info = try? parse(data) else { print("1 FAIL code=\(code)"); return }
    let newer = isVersion(info.version, newerThan: "1.0.0")
    print("1 GitHub 解析: v\(info.version) newerThan 1.0.0=\(newer) url=\(info.url?.prefix(60) ?? "") \(newer && info.url != nil ? "PASS" : "FAIL")")
}

// 2. 本仓库 404
fetch("https://api.github.com/repos/Monkey0803/MenuTools/releases/latest") { _, code in
    print("2 无 Release 仓库: code=\(code) \(code == 404 ? "PASS(视为已最新)" : "FAIL")")
}

// 3. appcast 回退
let appcast = #"{"version":"9.9.9","notes":"n","url":"https://x"}"#.data(using: .utf8)!
if let info = try? parse(appcast), info.version == "9.9.9" {
    print("3 appcast 回退: v\(info.version) PASS")
} else {
    print("3 appcast 回退: FAIL")
}

// 4. 版本比较边界
let cases: [(String, String, Bool)] = [("1.10.0", "1.9.9", true), ("1.0.0", "1.0.0", false), ("2.0", "1.9.9", true), ("1.0.0", "1.0.1", false)]
let ok = cases.allSatisfy { isVersion($0.0, newerThan: $0.1) == $0.2 }
print("4 版本比较边界: \(ok ? "PASS" : "FAIL")")
