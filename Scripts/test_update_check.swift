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

func normalizedVersion(_ raw: String) -> String {
    var version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if version.first == "v" || version.first == "V" { version.removeFirst() }
    if let buildIndex = version.firstIndex(of: "+") {
        version = String(version[..<buildIndex])
    }
    return version
}

enum VersionIdentifier {
    case numeric(Int)
    case text(String)
}

struct SemanticVersion: Comparable {
    let numbers: [Int]
    let prerelease: [VersionIdentifier]

    init?(_ raw: String) {
        let parts = normalizedVersion(raw).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = parts.first, !core.isEmpty else { return nil }
        let numberStrings = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !numberStrings.isEmpty, numberStrings.allSatisfy({ Int($0) != nil }) else { return nil }
        numbers = numberStrings.map { Int($0)! }
        if parts.count == 1 {
            prerelease = []
        } else {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty, !identifiers.contains(where: { $0.isEmpty }) else { return nil }
            prerelease = identifiers.map { Int($0).map(VersionIdentifier.numeric) ?? .text(String($0)) }
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { compare(lhs, rhs) == 0 }

    static func < (lhs: Self, rhs: Self) -> Bool { compare(lhs, rhs) < 0 }

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
            case (.numeric, .text): return -1
            case (.text, .numeric): return 1
            case let (.text(left), .text(right)):
                if left != right { return left < right ? -1 : 1 }
            }
        }
        return 0
    }
}

func isVersion(_ candidate: String, newerThan current: String) -> Bool {
    guard let candidate = SemanticVersion(candidate), let current = SemanticVersion(current) else { return false }
    return candidate > current
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

// 2. 明确不存在的仓库 404
fetch("https://api.github.com/repos/Monkey0803/MenuTools-update-check-no-release/releases/latest") { _, code in
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
let cases: [(String, String, Bool)] = [("1.10.0", "1.9.9", true), ("1.0.0", "1.0.0", false), ("2.0", "1.9.9", true), ("1.0.0", "1.0.1", false), ("1.0.1-beta", "1.0.0", true), ("1.0.1-beta", "1.0.1", false)]
let ok = cases.allSatisfy { isVersion($0.0, newerThan: $0.1) == $0.2 }
print("4 版本比较边界: \(ok ? "PASS" : "FAIL")")
