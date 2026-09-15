import Foundation
import Testing
@testable import MenuTools

// MARK: - 预设覆盖补全（旧数据迁移）

@Test("旧版预设数据缺少新字段时仍能解码，并标记为 v1")
func presetDecodesLegacyPayloadWithoutAppSettings() throws {
    let legacy = """
    [{
      "id": "6B29FC40-CA47-1067-B31D-00DD010662DA",
      "name": "夜间",
      "masterVolume": 0.3,
      "appVolumes": { "com.apple.Music": 0.2 },
      "createdAt": 760000000
    }]
    """

    let presets = try JSONDecoder().decode([AppVolumePreset].self, from: Data(legacy.utf8))
    let preset = try #require(presets.first)

    #expect(preset.name == "夜间")
    #expect(preset.masterVolume == 0.3)
    #expect(preset.appVolumes == ["com.apple.Music": 0.2])
    #expect(preset.appSettings.isEmpty)
    #expect(preset.schemaVersion == 1)
    #expect(preset.needsCoverageUpgrade)
}

@Test("新保存的预设写入当前版本号并携带每 App 细节")
func presetRoundTripsAppSettingsThroughCoding() throws {
    var preset = AppVolumePreset(
        id: UUID(),
        name: "工作",
        masterVolume: 0.6,
        appVolumes: ["com.apple.Music": 0.4],
        createdAt: Date(timeIntervalSince1970: 760_000_000)
    )
    preset.appSettings["com.apple.Music"] = AppVolumePresetAppSettings(
        equalizer: AppVolumeEqualizer(isEnabled: true, gains: AppVolumeEqualizerPreset.vocalClarity.gains),
        outputDeviceUID: "headphones",
        appGroup: .meeting,
        isFavorite: true
    )

    let data = try JSONEncoder().encode([preset])
    let decoded = try #require(try JSONDecoder().decode([AppVolumePreset].self, from: data).first)

    #expect(decoded.schemaVersion == AppVolumePreset.currentSchemaVersion)
    #expect(!decoded.needsCoverageUpgrade)
    let settings = try #require(decoded.appSettings["com.apple.Music"])
    #expect(settings.equalizer.isEnabled)
    #expect(settings.equalizer.gains == AppVolumeEqualizerPreset.vocalClarity.gains)
    #expect(settings.outputDeviceUID == "headphones")
    #expect(settings.appGroup == .meeting)
    #expect(settings.isFavorite)
}

// MARK: - 自定义 EQ 预设库

@Test("自定义 EQ 预设会裁剪增益、补齐频段并清洗名称")
func customEqualizerNormalizesGainsAndName() {
    let tooManyBands = AppVolumeCustomEqualizer(
        id: UUID(),
        name: "  超长名称" + String(repeating: "甲", count: 80) + "  ",
        gains: [99, -99, 3],
        createdAt: .distantPast
    ).normalized()

    #expect(tooManyBands.gains.count == AppVolumeEqualizer.bandFrequencies.count)
    #expect(tooManyBands.gains[0] == AppVolumeEqualizer.maximumGain)
    #expect(tooManyBands.gains[1] == AppVolumeEqualizer.minimumGain)
    #expect(tooManyBands.gains[2] == 3)
    #expect(tooManyBands.gains.suffix(6).allSatisfy { $0 == 0 })
    #expect(tooManyBands.name.count <= AppVolumeCustomEqualizer.maximumNameLength)
    #expect(!tooManyBands.name.hasPrefix(" "))
    #expect(!tooManyBands.name.hasSuffix(" "))

    let unnamed = AppVolumeCustomEqualizer(
        id: UUID(),
        name: "   ",
        gains: [],
        createdAt: .distantPast
    ).normalized()
    #expect(!unnamed.name.isEmpty)
    #expect(unnamed.gains.count == AppVolumeEqualizer.bandFrequencies.count)
}

@Test("自定义 EQ 预设可以从曲线匹配出相同增益")
func customEqualizerCapturesCurrentCurve() {
    let curve = AppVolumeEqualizerPreset.lateNight.gains
    let preset = AppVolumeCustomEqualizer(name: "夜间人声", gains: curve, createdAt: .distantPast).normalized()

    #expect(preset.gains == curve)
}

// MARK: - 归档版本迁移

@Test("旧版预设归档（v1）仍可导入，导出使用当前版本并包含自定义 EQ")
func presetArchiveMigratesLegacyVersion() throws {
    let legacyArchive = """
    {
      "version": 1,
      "presets": [{
        "id": "6B29FC40-CA47-1067-B31D-00DD010662DA",
        "name": "夜间",
        "masterVolume": 0.3,
        "appVolumes": { "com.apple.Music": 0.2 },
        "createdAt": 760000000
      }],
      "automationRules": []
    }
    """

    let archive = try JSONDecoder().decode(AppVolumePresetArchive.self, from: Data(legacyArchive.utf8))

    #expect(archive.version == 1)
    #expect(archive.equalizerPresets.isEmpty)
    #expect(archive.presets.first?.appSettings.isEmpty == true)

    let exported = try #require(
        try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                AppVolumePresetArchive(version: AppVolumePresetArchive.currentVersion, presets: [], automationRules: [])
            )
        ) as? [String: Any]
    )
    #expect(exported["version"] as? Int == AppVolumePresetArchive.currentVersion)
}