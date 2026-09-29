import Testing
@testable import MenuTools

@Test("更新检查不可用时优先解释启动失败")
func updateCheckAvailabilityExplainsFailure() {
    #expect(AppUpdateCheckAvailability.resolve(canCheck: true, startupError: nil) == .ready)
    #expect(AppUpdateCheckAvailability.resolve(canCheck: false, startupError: nil) == .temporarilyUnavailable)
    #expect(AppUpdateCheckAvailability.resolve(canCheck: false, startupError: "签名错误") == .startupFailed("签名错误"))
}

@Test("当前版本高于发布版本时识别为开发版")
func newerLocalVersionIsDevelopmentVersion() {
    #expect(
        AppUpdateVersionRelationship.resolve(current: "1.1.0", latestPublished: "1.0.4")
            == .developmentVersion
    )
}

@Test("当前版本等于发布版本时识别为最新版")
func equalVersionIsCurrentRelease() {
    #expect(
        AppUpdateVersionRelationship.resolve(current: "1.0.4", latestPublished: "1.0.4")
            == .currentRelease
    )
}

@Test("发布版本高于当前版本时识别为可更新")
func newerPublishedVersionIsUpdateAvailable() {
    #expect(
        AppUpdateVersionRelationship.resolve(current: "1.0.4", latestPublished: "1.1.0")
            == .updateAvailable
    )
}

@Test("版本号按数字段比较而不是字符串字典序")
func versionComparisonUsesNumericSegments() {
    #expect(
        AppUpdateVersionRelationship.resolve(current: "1.10.0", latestPublished: "1.9.0")
            == .developmentVersion
    )
}
