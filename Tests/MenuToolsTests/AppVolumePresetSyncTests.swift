import Foundation
import Testing
@testable import MenuTools

private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

private func makePreset(
    id: UUID = UUID(),
    name: String = "预设",
    volume: Double = 0.5,
    createdAt: Date,
    updatedAt: Date? = nil
) -> AppVolumePreset {
    AppVolumePreset(
        id: id,
        name: name,
        masterVolume: volume,
        appVolumes: ["com.apple.Music": volume],
        createdAt: createdAt,
        updatedAt: updatedAt
    )
}

private func makeEqualizer(
    id: UUID = UUID(),
    name: String = "曲线",
    createdAt: Date,
    updatedAt: Date? = nil
) -> AppVolumeCustomEqualizer {
    AppVolumeCustomEqualizer(
        id: id,
        name: name,
        gains: AppVolumeEqualizerPreset.lateNight.gains,
        createdAt: createdAt,
        updatedAt: updatedAt
    )
}

private func document(
    deviceName: String = "本机",
    updatedAt: Date = baseDate,
    presets: [AppVolumePreset] = [],
    rules: [AppVolumeAutomationRule] = [],
    equalizers: [AppVolumeCustomEqualizer] = [],
    presetTombstones: [String: Date] = [:],
    equalizerTombstones: [String: Date] = [:]
) -> AppVolumePresetSyncDocument {
    AppVolumePresetSyncDocument(
        formatVersion: AppVolumePresetSyncDocument.currentFormatVersion,
        deviceName: deviceName,
        updatedAt: updatedAt,
        presets: presets,
        automationRules: rules,
        equalizerPresets: equalizers,
        presetTombstones: presetTombstones,
        equalizerTombstones: equalizerTombstones
    )
}

@Test("同一预设按状态时间戳取较新的一方")
func presetMergePrefersNewerTimestamp() {
    let id = UUID()
    let local = document(presets: [makePreset(id: id, name: "本机新", createdAt: baseDate, updatedAt: baseDate.addingTimeInterval(60))])
    let remote = document(presets: [makePreset(id: id, name: "远端旧", createdAt: baseDate)])

    let merged = AppVolumePresetSyncMerge.merge(local: local, remote: remote)

    #expect(merged.presets.map(\.name) == ["本机新"])

    let remoteNewer = AppVolumePresetSyncMerge.merge(
        local: local,
        remote: document(presets: [makePreset(id: id, name: "远端新", createdAt: baseDate, updatedAt: baseDate.addingTimeInterval(120))])
    )
    #expect(remoteNewer.presets.map(\.name) == ["远端新"])
}

@Test("删除通过墓碑传播，删除后重建的预设仍保留")
func presetTombstoneDeletesAndAllowsRecreation() {
    let deletedID = UUID()
    let recreatedID = UUID()
    let local = document(presets: [
        makePreset(id: deletedID, name: "将被删除", createdAt: baseDate),
        makePreset(id: recreatedID, name: "删除后重建", createdAt: baseDate, updatedAt: baseDate.addingTimeInterval(600))
    ])
    let remote = document(
        presetTombstones: [
            deletedID.uuidString: baseDate.addingTimeInterval(120),
            recreatedID.uuidString: baseDate.addingTimeInterval(60)
        ]
    )

    let merged = AppVolumePresetSyncMerge.merge(local: local, remote: remote)

    // 删除时间晚于条目状态 → 消失；重建时间晚于墓碑 → 保留
    #expect(merged.presets.map(\.name) == ["删除后重建"])
    #expect(merged.presetTombstones.count == 2)
}

@Test("两端独有条目取并集，自动化规则同 ID 保留本机")
func presetMergeUnionsItemsAndKeepsLocalRules() {
    let localPreset = makePreset(name: "本机预设", createdAt: baseDate, updatedAt: baseDate.addingTimeInterval(10))
    let remotePreset = makePreset(name: "远端预设", createdAt: baseDate, updatedAt: baseDate.addingTimeInterval(20))
    let sharedRuleID = UUID()
    let localRule = AppVolumeAutomationRule(
        id: sharedRuleID,
        presetID: localPreset.id,
        outputDeviceUID: "speaker",
        isEnabled: true
    )
    let remoteRule = AppVolumeAutomationRule(
        id: sharedRuleID,
        presetID: remotePreset.id,
        outputDeviceUID: nil,
        isEnabled: false
    )
    let remoteOnlyRule = AppVolumeAutomationRule(
        id: UUID(),
        presetID: remotePreset.id,
        outputDeviceUID: nil,
        isEnabled: true
    )

    let merged = AppVolumePresetSyncMerge.merge(
        local: document(presets: [localPreset], rules: [localRule]),
        remote: document(presets: [remotePreset], rules: [remoteRule, remoteOnlyRule])
    )

    #expect(Set(merged.presets.map(\.name)) == ["本机预设", "远端预设"])
    #expect(merged.automationRules.count == 2)
    let keptRule = try? #require(merged.automationRules.first { $0.id == sharedRuleID })
    #expect(keptRule?.outputDeviceUID == "speaker")
}

@Test("墓碑合并取较晚的删除时间，自定义 EQ 同样受墓碑约束")
func tombstoneMergeKeepsLatestDeletion() {
    let id = UUID()
    let merged = AppVolumePresetSyncMerge.merge(
        local: document(
            equalizers: [makeEqualizer(id: id, createdAt: baseDate)],
            equalizerTombstones: [id.uuidString: baseDate.addingTimeInterval(10)]
        ),
        remote: document(
            equalizerTombstones: [id.uuidString: baseDate.addingTimeInterval(300)]
        )
    )

    #expect(merged.equalizerTombstones[id.uuidString] == baseDate.addingTimeInterval(300))
    #expect(merged.equalizerPresets.isEmpty)
}

@Test("合并结果的更新时间取两边较晚的一方")
func mergeTakesLatestUpdateTimestamp() {
    let merged = AppVolumePresetSyncMerge.merge(
        local: document(updatedAt: baseDate),
        remote: document(updatedAt: baseDate.addingTimeInterval(500))
    )

    #expect(merged.updatedAt >= baseDate.addingTimeInterval(500))
}

@Test("同步文档只接受当前格式版本")
func syncDocumentValidatesVersion() throws {
    var future = document()
    future.formatVersion = AppVolumePresetSyncDocument.currentFormatVersion + 1

    #expect(throws: AppVolumePresetSyncError.unsupportedVersion) {
        try future.validated()
    }
    #expect(try document().validated().formatVersion == AppVolumePresetSyncDocument.currentFormatVersion)
}

@Test("同步文档可经信封往返，且与剪贴板归档的 magic 互不兼容")
func syncDocumentRoundTripsThroughEnvelope() throws {
    let preset = makePreset(name: "通勤", createdAt: baseDate, updatedAt: baseDate)
    let original = document(presets: [preset])

    let sealed = try original.encryptedShared(passphrase: "口令")
    let opened = try AppVolumePresetSyncDocument.decryptShared(sealed, passphrase: "口令")

    #expect(opened.presets.map(\.name) == ["通勤"])
    #expect(String(decoding: sealed.prefix(8), as: UTF8.self) == "MTVOL001")

    // 用剪贴板 magic 写的载荷不能被音量同步读出来
    let clipboardLikeBlob = try EncryptedArchiveEnvelope.seal(
        original,
        passphrase: "口令",
        magic: "MTCLIP01"
    )
    #expect(throws: (any Error).self) {
        try AppVolumePresetSyncDocument.decryptShared(clipboardLikeBlob, passphrase: "口令")
    }
}