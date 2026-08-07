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

@Test("增益、时长和最小步长必须在支持范围内")
func outOfRangeScrollValuesThrow() {
    let invalidValues: [(inout AppBackupSettings) -> Void] = [
        { $0.scrollGain = 0.09 },
        { $0.scrollDuration = 0.04 },
        { $0.scrollMinStep = 0.99 }
    ]

    for mutate in invalidValues {
        var settings = AppBackupSettings.fixture
        mutate(&settings)
        let document = AppBackupDocument.current(
            settings: settings,
            rightClick: .default,
            appVersion: "1.0.1",
            createdAt: Date()
        )

        #expect(throws: (any Error).self) {
            try document.validated()
        }
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
    let document = AppBackupDocument.current(
        settings: settings,
        rightClick: .default,
        appVersion: "1.0.1",
        createdAt: Date()
    )

    #expect(throws: (any Error).self) {
        try document.validated()
    }
}

@Test("未知 JSON 字段会被忽略")
func unknownJSONFieldsAreIgnored() throws {
    let data = #"{"formatVersion":1,"createdAt":0,"appVersion":"1.0.1","settings":{"menuBarIcon":"wrench.and.screwdriver.fill","menuBarShowTitle":false,"togglesShowTitle":false,"preferredTerminal":"system","autoCheckUpdate":true,"appLanguage":"system","scrollEnabled":false,"scrollSmoothVertical":true,"scrollSmoothHorizontal":true,"scrollInvertVertical":false,"scrollInvertHorizontal":false,"scrollGain":1,"scrollDuration":0.35,"scrollMinStep":8,"scrollTouchpadEmulation":true,"scrollAccelModifier":0,"scrollShiftModifier":0,"scrollDisableModifier":0,"unexpectedSetting":"do not execute"},"rightClick":{"enabled":{},"unexpectedAction":"do not execute"},"unexpectedTopLevel":"do not execute"}"#.data(using: .utf8)!

    let document = try JSONDecoder().decode(AppBackupDocument.self, from: data)

    #expect(document.settings == .fixture)
    #expect(document.rightClick == RightClickConfig(enabled: [:]))
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
