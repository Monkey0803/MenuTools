import Foundation
import Testing

private var releaseRepositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

@Test("Finder 扩展与主程序的版本号一致")
func finderExtensionVersionMatchesHost() throws {
    let hostURL = releaseRepositoryRoot.appendingPathComponent("Resources/Info.plist")
    let extensionURL = releaseRepositoryRoot.appendingPathComponent("Extension/Info.plist")
    let host = try #require(NSDictionary(contentsOf: hostURL) as? [String: Any])
    let finderExtension = try #require(NSDictionary(contentsOf: extensionURL) as? [String: Any])

    for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
        #expect(finderExtension[key] as? String == host[key] as? String, "扩展的 \(key) 必须与主程序一致")
    }
}

@Test("右键健康检查只报告实际测量到的配置存储和辅助功能权限")
func rightClickHealthCheckReportsMeasuredState() throws {
    let url = releaseRepositoryRoot.appendingPathComponent("Sources/MenuTools/RightClickHealthCheckView.swift")
    let source = try String(contentsOf: url, encoding: .utf8)

    #expect(source.contains("RightClickConfigStore.fileURL"))
    #expect(source.contains("RightClickConfigStore.isWritableDirectory(configBase)"))
    #expect(source.contains("health.storage.name"))
    #expect(source.contains("health.accessibility.name"))
    #expect(source.contains("RuntimePermissionSettingsLink.url(for: .accessibility)"))
    #expect(source.contains("NSApplication.didBecomeActiveNotification"))
    #expect(!source.contains("health.automation.name"))
}
