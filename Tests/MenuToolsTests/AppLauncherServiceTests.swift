import Foundation
import Testing
@testable import MenuTools

@Test("应用启动器按收藏、最近使用和名称排序")
func appLauncherSortsFavoritesAndRecents() {
    let apps = [
        LaunchableApp(path: "/Applications/Safari.app", name: "Safari", bundleIdentifier: "com.apple.Safari"),
        LaunchableApp(path: "/Applications/Notes.app", name: "Notes", bundleIdentifier: "com.apple.Notes"),
        LaunchableApp(path: "/Applications/Terminal.app", name: "Terminal", bundleIdentifier: "com.apple.Terminal")
    ]

    let result = AppLauncherCatalog.visibleApps(
        apps,
        query: "",
        favoritePaths: ["/Applications/Safari.app"],
        recentPaths: ["/Applications/Terminal.app"]
    )

    #expect(result.map(\.name) == ["Safari", "Terminal", "Notes"])
}

@Test("应用启动器搜索支持大小写和名称匹配")
func appLauncherSearchMatchesName() {
    let apps = [
        LaunchableApp(path: "/Applications/Safari.app", name: "Safari", bundleIdentifier: "com.apple.Safari"),
        LaunchableApp(path: "/Applications/Notes.app", name: "Notes", bundleIdentifier: "com.apple.Notes")
    ]

    let result = AppLauncherCatalog.visibleApps(
        apps,
        query: "saf",
        favoritePaths: [],
        recentPaths: []
    )

    #expect(result.map(\.name) == ["Safari"])
}

@Test("应用启动器搜索支持应用包目录名称")
func appLauncherSearchMatchesPackageName() {
    let apps = [
        LaunchableApp(
            path: "/Applications/Visual Studio Code.app",
            name: "Code",
            bundleIdentifier: "com.microsoft.VSCode"
        )
    ]

    let result = AppLauncherCatalog.visibleApps(
        apps,
        query: "vis",
        favoritePaths: [],
        recentPaths: []
    )

    #expect(result.map(\.path) == ["/Applications/Visual Studio Code.app"])
}

@Test("启动器最近使用只保留仍然存在的前几条，并保持记录顺序")
func appLauncherPanelPolicyFiltersRecents() {
    let paths = ["/Applications/Safari.app", "/Applications/Gone.app", "/Applications/Notes.app"]
    let existing: (String) -> Bool = { $0 != "/Applications/Gone.app" }

    #expect(
        AppLauncherPanelPolicy.recentPaths(paths, exists: existing, limit: 5)
            == ["/Applications/Safari.app", "/Applications/Notes.app"]
    )
    // 超过上限只取前 N 条
    #expect(
        AppLauncherPanelPolicy.recentPaths(paths, exists: existing, limit: 1)
            == ["/Applications/Safari.app"]
    )
    // 有搜索词时不再展示最近使用与收藏分组
    #expect(AppLauncherPanelPolicy.showsRecents(query: "  "))
    #expect(!AppLauncherPanelPolicy.showsRecents(query: "note"))
}

@Test("收藏会写入偏好并在新实例里恢复")
@MainActor
func appLauncherToggleFavoritePersists() throws {
    let suiteName = "AppLauncherServiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)

    let service = AppLauncherService(defaults: defaults)
    let app = LaunchableApp(
        path: "/Applications/Notes.app",
        name: "Notes",
        bundleIdentifier: "com.apple.Notes"
    )

    #expect(service.favoritePaths.isEmpty)
    service.toggleFavorite(app)
    #expect(service.favoritePaths.contains(app.path))

    // 关掉再开一个实例仍保留，且再次切换可取消
    #expect(AppLauncherService(defaults: defaults).favoritePaths.contains(app.path))
    service.toggleFavorite(app)
    #expect(!service.favoritePaths.contains(app.path))
    #expect(AppLauncherService(defaults: defaults).favoritePaths.isEmpty)
}
