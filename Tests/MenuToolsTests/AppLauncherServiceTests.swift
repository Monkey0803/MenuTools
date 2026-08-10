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
