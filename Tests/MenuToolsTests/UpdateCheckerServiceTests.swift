import Foundation
import Testing
@testable import MenuTools

@Test("预发布版本高于旧的正式版本")
@MainActor
func prereleaseVersionIsNewerThanOlderRelease() {
    #expect(UpdateCheckerService.isVersion("1.0.1-beta", newerThan: "1.0.0"))
}

@Test("相同版本的预发布版本低于正式版本")
@MainActor
func prereleaseVersionIsOlderThanSameRelease() {
    #expect(!UpdateCheckerService.isVersion("1.0.1-beta", newerThan: "1.0.1"))
}

@Test("appcast 版本会规范化 v 前缀并保留下载地址")
@MainActor
func appcastVersionNormalizesPrefix() throws {
    let data = Data(#"{"version":"v1.0.2","notes":"更新","url":"https://example.com/MenuTools.zip"}"#.utf8)

    let info = try UpdateCheckerService.parse(data)

    #expect(info.version == "1.0.2")
    #expect(info.url == "https://example.com/MenuTools.zip")
}

@Test("GitHub Release 版本会规范化 v 前缀并选择安装包资产")
@MainActor
func githubReleaseVersionNormalizesPrefixAndSelectsAsset() throws {
    let data = Data(#"{"tag_name":"v1.0.2","body":"更新","html_url":"https://example.com/release","assets":[{"name":"checksums.txt","browser_download_url":"https://example.com/checksums.txt"},{"name":"MenuTools.zip","browser_download_url":"https://example.com/MenuTools.zip"}]}"#.utf8)

    let info = try UpdateCheckerService.parse(data)

    #expect(info.version == "1.0.2")
    #expect(info.url == "https://example.com/MenuTools.zip")
}
