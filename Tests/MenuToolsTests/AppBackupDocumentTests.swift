import Foundation
import Testing
@testable import MenuTools

@Test("完整备份文档可以通过 JSON 往返")
func completeDocumentRoundTripsThroughJSON() throws {
    let settings = AppBackupSettings(
        menuBarIcon: "terminal.fill",
        menuBarShowTitle: true,
        togglesShowTitle: true,
        preferredTerminal: "iTerm2",
        autoCheckUpdate: false,
        appLanguage: "zh-Hans",
        scrollEnabled: true,
        scrollSmoothVertical: false,
        scrollSmoothHorizontal: true,
        scrollInvertVertical: true,
        scrollInvertHorizontal: false,
        scrollGain: 1.5,
        scrollDuration: 0.4,
        scrollMinStep: 12,
        scrollTouchpadEmulation: false,
        scrollAccelModifier: 1 << 20,
        scrollShiftModifier: 1 << 17,
        scrollDisableModifier: 0
    )
    let rightClick = RightClickConfig(enabled: [
        RightClickItem.newFolder.rawValue: true,
        RightClickItem.copyAbsolutePath.rawValue: false
    ])
    let document = AppBackupDocument.current(
        settings: settings,
        rightClick: rightClick,
        appVersion: "1.0.1",
        createdAt: Date(timeIntervalSince1970: 1_754_534_400)
    )

    let data = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(AppBackupDocument.self, from: data)

    #expect(decoded == document)
    #expect(decoded.formatVersion == 1)
}

@Test("不支持的格式版本会被拒绝")
func unsupportedFormatVersionThrows() {
    let document = AppBackupDocument(
        formatVersion: 2,
        createdAt: Date(),
        appVersion: "1.0.1",
        settings: .fixture,
        rightClick: .default
    )

    #expect(throws: AppBackupValidationError.unsupportedFormatVersion(2)) {
        try document.validated()
    }
}

@Test("低于增益下限会抛出精确校验错误")
func gainBelowLowerBoundThrowsExactError() {
    var settings = AppBackupSettings.fixture
    settings.scrollGain = 0.09

    #expect(throws: AppBackupValidationError.invalidGain(0.09)) {
        try document(settings: settings).validated()
    }
}

@Test("高于增益上限会抛出精确校验错误")
func gainAboveUpperBoundThrowsExactError() {
    var settings = AppBackupSettings.fixture
    settings.scrollGain = 10.01

    #expect(throws: AppBackupValidationError.invalidGain(10.01)) {
        try document(settings: settings).validated()
    }
}

@Test("低于时长下限会抛出精确校验错误")
func durationBelowLowerBoundThrowsExactError() {
    var settings = AppBackupSettings.fixture
    settings.scrollDuration = 0.04

    #expect(throws: AppBackupValidationError.invalidDuration(0.04)) {
        try document(settings: settings).validated()
    }
}

@Test("高于时长上限会抛出精确校验错误")
func durationAboveUpperBoundThrowsExactError() {
    var settings = AppBackupSettings.fixture
    settings.scrollDuration = 2.01

    #expect(throws: AppBackupValidationError.invalidDuration(2.01)) {
        try document(settings: settings).validated()
    }
}

@Test("低于最小步长下限会抛出精确校验错误")
func minimumStepBelowLowerBoundThrowsExactError() {
    var settings = AppBackupSettings.fixture
    settings.scrollMinStep = 0.99

    #expect(throws: AppBackupValidationError.invalidMinimumStep(0.99)) {
        try document(settings: settings).validated()
    }
}

@Test("高于最小步长上限会抛出精确校验错误")
func minimumStepAboveUpperBoundThrowsExactError() {
    var settings = AppBackupSettings.fixture
    settings.scrollMinStep = 100.01

    #expect(throws: AppBackupValidationError.invalidMinimumStep(100.01)) {
        try document(settings: settings).validated()
    }
}

@Test("平滑滚动参数的当前 UI 边界值有效")
func currentScrollRangeBoundariesAreAccepted() throws {
    var settings = AppBackupSettings.fixture
    settings.scrollGain = 0.1
    settings.scrollDuration = 2
    settings.scrollMinStep = 100
    let document = AppBackupDocument.current(
        settings: settings,
        rightClick: .default,
        appVersion: "1.0.1",
        createdAt: Date()
    )

    #expect(try document.validated() == document)
}

@Test("修饰键只允许四种 Cocoa 修饰键的组合")
func invalidModifierValueThrows() {
    var settings = AppBackupSettings.fixture
    settings.scrollAccelModifier = 1 << 16
    #expect(throws: AppBackupValidationError.invalidModifier("scrollAccelModifier", 1 << 16)) {
        try document(settings: settings).validated()
    }
}

@Test("未知 JSON 字段会被忽略")
func unknownJSONFieldsAreIgnored() throws {
    let data = #"{"formatVersion":1,"createdAt":0,"appVersion":"1.0.1","settings":{"menuBarIcon":"wrench.and.screwdriver.fill","menuBarShowTitle":false,"togglesShowTitle":false,"preferredTerminal":"system","autoCheckUpdate":true,"appLanguage":"system","scrollEnabled":false,"scrollSmoothVertical":true,"scrollSmoothHorizontal":true,"scrollInvertVertical":false,"scrollInvertHorizontal":false,"scrollGain":1,"scrollDuration":0.35,"scrollMinStep":8,"scrollTouchpadEmulation":true,"scrollAccelModifier":0,"scrollShiftModifier":0,"scrollDisableModifier":0,"unexpectedSetting":"do not execute"},"rightClick":{"enabled":{},"unexpectedAction":"do not execute"},"unexpectedTopLevel":"do not execute"}"#.data(using: .utf8)!

    let document = try JSONDecoder().decode(AppBackupDocument.self, from: data)

    #expect(document.settings == .fixture)
    #expect(document.rightClick == RightClickConfig(enabled: [:]))

    let reencodedData = try JSONEncoder().encode(document)
    let topLevel = try #require(
        JSONSerialization.jsonObject(with: reencodedData) as? [String: Any]
    )
    let reencodedSettings = try #require(topLevel["settings"] as? [String: Any])
    let reencodedRightClick = try #require(topLevel["rightClick"] as? [String: Any])

    #expect(topLevel["unexpectedTopLevel"] == nil)
    #expect(reencodedSettings["unexpectedSetting"] == nil)
    #expect(reencodedRightClick["unexpectedAction"] == nil)
}

private func document(settings: AppBackupSettings) -> AppBackupDocument {
    AppBackupDocument.current(
        settings: settings,
        rightClick: .default,
        appVersion: "1.0.1",
        createdAt: Date()
    )
}

private extension AppBackupSettings {
    static let fixture = AppBackupSettings(
        menuBarIcon: "wrench.and.screwdriver.fill",
        menuBarShowTitle: false,
        togglesShowTitle: false,
        preferredTerminal: "system",
        autoCheckUpdate: true,
        appLanguage: "system",
        scrollEnabled: false,
        scrollSmoothVertical: true,
        scrollSmoothHorizontal: true,
        scrollInvertVertical: false,
        scrollInvertHorizontal: false,
        scrollGain: 1,
        scrollDuration: 0.35,
        scrollMinStep: 8,
        scrollTouchpadEmulation: true,
        scrollAccelModifier: 0,
        scrollShiftModifier: 0,
        scrollDisableModifier: 0
    )
}
