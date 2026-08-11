import AppKit
import Foundation
import Observation

/// 可从菜单栏启动的应用信息。
struct LaunchableApp: Identifiable, Equatable, Hashable, Sendable {
    let path: String
    let name: String
    let bundleIdentifier: String?

    var id: String { path }
}

enum AppLauncherCatalog {
    /// 按搜索、收藏和最近使用状态生成菜单展示顺序。
    static func visibleApps(
        _ apps: [LaunchableApp],
        query: String,
        favoritePaths: Set<String>,
        recentPaths: [String],
        limit: Int = 12
    ) -> [LaunchableApp] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let filtered = apps.filter { app in
            guard !normalizedQuery.isEmpty else { return true }
            let packageName = URL(fileURLWithPath: app.path)
                .deletingPathExtension()
                .lastPathComponent
            let searchableText = "\(app.name) \(packageName)"
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return searchableText.contains(normalizedQuery)
        }
        let recentRank = Dictionary(uniqueKeysWithValues: recentPaths.enumerated().map { ($1, $0) })
        return filtered.sorted { lhs, rhs in
            let leftFavorite = favoritePaths.contains(lhs.path)
            let rightFavorite = favoritePaths.contains(rhs.path)
            if leftFavorite != rightFavorite { return leftFavorite }

            let leftRecent = recentRank[lhs.path]
            let rightRecent = recentRank[rhs.path]
            if leftRecent != nil || rightRecent != nil {
                if leftRecent == nil { return false }
                if rightRecent == nil { return true }
                return leftRecent! < rightRecent!
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        .prefix(max(limit, 0))
        .map { $0 }
    }
}

@MainActor
@Observable
final class AppLauncherService {
    static let shared = AppLauncherService()

    static let favoritesKey = "appLauncher.favoritePaths"
    static let recentKey = "appLauncher.recentPaths"

    private(set) var apps: [LaunchableApp] = []
    var query = ""
    private(set) var favoritePaths: Set<String>
    private(set) var recentPaths: [String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.favoritePaths = Set(defaults.stringArray(forKey: Self.favoritesKey) ?? [])
        self.recentPaths = defaults.stringArray(forKey: Self.recentKey) ?? []
    }

    var visibleApps: [LaunchableApp] {
        AppLauncherCatalog.visibleApps(
            apps,
            query: query,
            favoritePaths: favoritePaths,
            recentPaths: recentPaths
        )
    }

    var favoriteApps: [LaunchableApp] {
        AppLauncherCatalog.visibleApps(
            apps.filter { favoritePaths.contains($0.path) },
            query: "",
            favoritePaths: favoritePaths,
            recentPaths: recentPaths,
            limit: 6
        )
    }

    func refresh() {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        var discovered: [LaunchableApp] = []
        var seenBundleIDs = Set<String>()
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension == "app" {
                guard let app = Self.descriptor(for: url) else { continue }
                if let bundleIdentifier = app.bundleIdentifier,
                   !seenBundleIDs.insert(bundleIdentifier).inserted {
                    continue
                }
                discovered.append(app)
            }
        }
        apps = discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func toggleFavorite(_ app: LaunchableApp) {
        if favoritePaths.contains(app.path) {
            favoritePaths.remove(app.path)
        } else {
            favoritePaths.insert(app.path)
        }
        defaults.set(Array(favoritePaths).sorted(), forKey: Self.favoritesKey)
    }

    func launch(_ app: LaunchableApp) -> Bool {
        guard NSWorkspace.shared.open(URL(fileURLWithPath: app.path)) else { return false }
        recentPaths.removeAll { $0 == app.path }
        recentPaths.insert(app.path, at: 0)
        recentPaths = Array(recentPaths.prefix(12))
        defaults.set(recentPaths, forKey: Self.recentKey)
        return true
    }

    func application(atPath path: String) -> LaunchableApp? {
        if let app = apps.first(where: { $0.path == path }) {
            return app
        }
        return Self.descriptor(for: URL(fileURLWithPath: path))
    }

    /// 返回最近的外部前台应用；设置窗口激活后不会把 MenuTools 自身返回给调用方。
    func frontmostExternalApplication() -> LaunchableApp? {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let frontmostProcess = NSWorkspace.shared.frontmostApplication
        let process: NSRunningApplication?

        if frontmostProcess?.processIdentifier == ownProcessIdentifier {
            guard let info = WindowManagementService.shared.focusedApplicationInfo() else { return nil }
            process = NSRunningApplication(processIdentifier: info.processIdentifier)
        } else {
            process = frontmostProcess
        }

        guard let url = process?.bundleURL else { return nil }
        return Self.descriptor(for: url)
    }

    private static func descriptor(for url: URL) -> LaunchableApp? {
        guard let bundle = Bundle(url: url) else { return nil }
        let packageName = url.deletingPathExtension().lastPathComponent
        let bundleName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        // Finder 中显示的是应用包名称；例如 VS Code 的 Bundle 名称是 Code，
        // 但用户实际选择的是“Visual Studio Code.app”。
        let name = packageName.isEmpty ? (bundleName ?? url.lastPathComponent) : packageName
        return LaunchableApp(
            path: url.path,
            name: name,
            bundleIdentifier: bundle.bundleIdentifier
        )
    }
}
