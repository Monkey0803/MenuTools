import CoreAudio
import Foundation
import Testing
@testable import MenuTools

@Test("切换输出设备会恢复该设备已记忆的主音量")
@MainActor
func outputDeviceSelectionRestoresRememberedVolume() throws {
    let defaults = try makeEnhancementDefaults("outputMemory")
    let backend = EnhancedFakeAppVolumeBackend()
    let speaker = AudioOutputDevice(id: 11, uid: "speaker", name: "Mac 扬声器", isDefault: true)
    let headphones = AudioOutputDevice(id: 12, uid: "headphones", name: "AirPods", isDefault: false)
    backend.outputDevices = [speaker, headphones]
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(output: .fixture(deviceID: speaker.id, deviceUID: speaker.uid))

    service.setMasterVolume(0.34)
    service.selectOutputDevice(headphones)
    service.setMasterVolume(0.72)
    service.selectOutputDevice(speaker)

    #expect(backend.selectedOutputIDs == [headphones.id, speaker.id])
    #expect(backend.masterVolumes.last == 0.34)
    #expect(service.output.deviceUID == speaker.uid)
}

@Test("主音量步长会持久化并限制在有效范围")
@MainActor
func masterVolumeStepPersistsAndClamps() throws {
    let defaults = try makeEnhancementDefaults("volumeStep")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(output: .fixture(volume: 0.96))

    service.setVolumeStep(0.08)
    service.adjustMasterVolume(increase: true)

    #expect(service.volumeStep == 0.08)
    #expect(backend.masterVolumes.last == 1)
    let restored = AppVolumeService(backend: EnhancedFakeAppVolumeBackend(), userDefaults: defaults)
    #expect(restored.volumeStep == 0.08)
}

@Test("收藏筛选只显示收藏 App，失败路由可重试或旁路恢复")
@MainActor
func favoritesFilterAndRouteRecoveryWork() throws {
    let defaults = try makeEnhancementDefaults("favoritesAndRetry")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music, .podcasts])
    service.setEnabled(true)
    service.toggleFavorite(for: "com.apple.Music")
    service.setSessionFilter(.favorites)

    #expect(service.filteredSessions.map(\.rootBundleID) == ["com.apple.Music"])

    backend.applyError = .unsupportedFormat
    service.setVolume(0.4, for: "com.apple.Music")
    #expect(service.session(id: "com.apple.Music")?.errorMessage != nil)

    backend.applyError = nil
    service.retryRoute(for: "com.apple.Music")
    #expect(service.session(id: "com.apple.Music")?.errorMessage == nil)

    service.bypassRoute(for: "com.apple.Music")
    #expect(service.session(id: "com.apple.Music")?.volume == 1)
}

@Test("音量预设可应用，并可按输出设备规则自动触发一次")
@MainActor
func volumePresetAndOutputAutomationApply() throws {
    let defaults = try makeEnhancementDefaults("presetAutomation")
    let backend = EnhancedFakeAppVolumeBackend()
    let headphones = AudioOutputDevice(id: 12, uid: "headphones", name: "AirPods", isDefault: true)
    backend.outputDevices = [headphones]
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music], output: .fixture(deviceID: headphones.id, deviceUID: headphones.uid))

    let preset = service.savePreset(named: "通勤", masterVolume: 0.3, appVolumes: ["com.apple.Music": 0.5])
    service.addAutomationRule(presetID: preset.id, outputDeviceUID: headphones.uid)
    service.evaluateAutomation(now: Date(timeIntervalSince1970: 1_800_000_000))
    service.evaluateAutomation(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(service.output.volume == 0.3)
    #expect(service.session(id: "com.apple.Music")?.volume == 0.5)
    #expect(backend.masterVolumes.filter { $0 == 0.3 }.count == 1)
}

@Test("音量预设会保留未发声 App 的下次启动音量")
@MainActor
func volumePresetKeepsInactiveAppVolume() throws {
    let defaults = try makeEnhancementDefaults("inactivePreset")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music])
    let preset = service.savePreset(named: "音乐", appVolumes: ["com.apple.Music": 0.42])

    backend.send(candidates: [])
    service.applyPreset(id: preset.id)

    #expect(service.session(id: "com.apple.Music")?.volume == 0.42)
}

@Test("增强模式支持最高 150% 增益且 DSP 仍限制削波")
@MainActor
func boostModeAndLimiterWork() throws {
    let defaults = try makeEnhancementDefaults("boost")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music])

    service.setBoostEnabled(true)
    service.setEnabled(true)
    service.setVolume(1.5, for: "com.apple.Music")

    #expect(service.session(id: "com.apple.Music")?.volume == 1.5)
    #expect(backend.applied.last?.volume == 1.5)
    #expect(AppVolumeSafetyPolicy.maximumGain(boostEnabled: true) == 1.5)
    var samples: [Float] = [1, -1]
    _ = AppVolumeDSP.applyGain(to: &samples, from: 1.5, to: 1.5)
    #expect(samples == [1, -1])
}

@Test("输入设备音量与静音可由服务层控制")
@MainActor
func inputVolumeAndMuteWork() throws {
    let defaults = try makeEnhancementDefaults("input")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(input: .fixture)

    service.setInputVolume(0.61)
    service.setInputMuted(true)

    #expect(backend.inputVolumes == [0.61])
    #expect(backend.inputMutedStates == [true])
    #expect(service.input.volume == 0.61)
    #expect(service.input.isMuted)
}

@Test("自动化规则可组合时间、专注模式、前台 App 和 Wi-Fi 条件")
func automationRuleSupportsAllConditions() {
    let rule = AppVolumeAutomationRule(
        id: UUID(),
        presetID: UUID(),
        outputDeviceUID: "airpods",
        isEnabled: true,
        startMinute: 22 * 60,
        endMinute: 6 * 60,
        requiresFocusMode: true,
        launchBundleID: "us.zoom.xos",
        wifiName: "Office"
    )
    let context = AppVolumeAutomationContext(
        date: Date(timeIntervalSince1970: 1_800_025_200),
        outputDeviceUID: "airpods",
        isFocusModeEnabled: true,
        frontmostBundleID: "us.zoom.xos",
        wifiName: "Office"
    )

    #expect(rule.matches(context))
    #expect(!rule.matches(AppVolumeAutomationContext(
        date: context.date,
        outputDeviceUID: "airpods",
        isFocusModeEnabled: false,
        frontmostBundleID: "us.zoom.xos",
        wifiName: "Office"
    )))
}

@Test("自动化规则编辑会清理空白条件并持久化")
@MainActor
func automationRuleEditingNormalizesConditions() throws {
    let defaults = try makeEnhancementDefaults("automationEditing")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    let preset = service.savePreset(named: "工作")
    service.addAutomationRule(presetID: preset.id, outputDeviceUID: "speaker")
    let rule = try #require(service.automationRules.first)

    service.updateAutomationRule(
        AppVolumeAutomationRule(
            id: rule.id,
            presetID: preset.id,
            outputDeviceUID: nil,
            isEnabled: true,
            startMinute: 120,
            endMinute: 60,
            requiresFocusMode: nil,
            launchBundleID: "  ",
            wifiName: " Office Wi-Fi "
        )
    )

    let updated = try #require(service.automationRules.first)
    #expect(updated.outputDeviceUID == nil)
    #expect(updated.launchBundleID == nil)
    #expect(updated.wifiName == "Office Wi-Fi")
}

@Test("自动化应用会记录执行结果并可撤销到执行前配置")
@MainActor
func automationExecutionCanBeUndone() throws {
    let defaults = try makeEnhancementDefaults("automationUndo")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music], output: .fixture(volume: 0.7))
    service.setVolume(0.8, for: "com.apple.Music")
    let preset = service.savePreset(named: "夜间", masterVolume: 0.3, appVolumes: ["com.apple.Music": 0.2])
    service.addAutomationRule(presetID: preset.id, outputDeviceUID: "speaker")

    service.evaluateAutomation(now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(service.automationExecutions.count == 1)
    #expect(service.canUndoLatestAutomation)
    service.undoLatestAutomation()
    #expect(service.output.volume == 0.7)
    #expect(service.session(id: "com.apple.Music")?.volume == 0.8)
    #expect(!service.canUndoLatestAutomation)
}

@Test("旧版 App 音量配置缺少新增字段时仍可恢复")
@MainActor
func legacyProfilesRemainReadable() throws {
    let defaults = try makeEnhancementDefaults("legacyProfiles")
    let legacyProfile = LegacyAppVolumeProfile(
        rootBundleID: "com.apple.Music",
        displayName: "音乐",
        bundleURL: URL(fileURLWithPath: "/System/Applications/Music.app"),
        volume: 0.72,
        lastNonzeroVolume: 0.72,
        audioBundleIDs: ["com.apple.Music"],
        lastAdjustedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    defaults.set(
        try JSONEncoder().encode([legacyProfile.rootBundleID: legacyProfile]),
        forKey: "appVolume.profiles.v1"
    )
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)

    backend.send(candidates: [.music])

    let restored = try #require(service.session(id: legacyProfile.rootBundleID))
    #expect(restored.volume == 0.72)
    #expect(!restored.isFavorite)
}

@Test("会议压低期间重启后，会议结束会恢复原始音量")
@MainActor
func meetingDuckingRestoresOriginalVolumeAfterRestart() throws {
    let defaults = try makeEnhancementDefaults("meetingDuckingRestart")
    let firstBackend = EnhancedFakeAppVolumeBackend()
    let firstService = AppVolumeService(backend: firstBackend, userDefaults: defaults)
    firstService.setMeetingDuckingEnabled(true)
    firstService.setMeetingDuckingFactor(0.4)
    firstBackend.send(candidates: [.music, .zoom])
    #expect(firstService.session(id: "com.apple.Music")?.volume == 0.4)

    let restartedBackend = EnhancedFakeAppVolumeBackend()
    let restartedService = AppVolumeService(backend: restartedBackend, userDefaults: defaults)
    restartedBackend.send(candidates: [.music])

    #expect(!restartedService.isMeetingDuckingActive)
    #expect(restartedService.session(id: "com.apple.Music")?.volume == 1)
}

@Test("自动化在同一天重启后不会重复应用")
@MainActor
func automationDoesNotReapplyAfterRestartOnSameDay() throws {
    let defaults = try makeEnhancementDefaults("automationRestart")
    let firstBackend = EnhancedFakeAppVolumeBackend()
    let firstService = AppVolumeService(backend: firstBackend, userDefaults: defaults)
    firstBackend.send(candidates: [.music], output: .fixture(volume: 0.7))
    let preset = firstService.savePreset(named: "夜间", masterVolume: 0.3, appVolumes: ["com.apple.Music": 0.2])
    firstService.addAutomationRule(presetID: preset.id, outputDeviceUID: "speaker")
    firstService.evaluateAutomation(now: .now)
    #expect(firstService.automationExecutions.count == 1)

    let restartedBackend = EnhancedFakeAppVolumeBackend()
    let restartedService = AppVolumeService(backend: restartedBackend, userDefaults: defaults)
    restartedBackend.send(candidates: [.music], output: .fixture(volume: 0.9))

    #expect(restartedService.automationExecutions.count == 1)
    #expect(restartedService.output.volume == 0.9)
}

@Test("旧自动化执行记录在同名输出设备上会阻止当日重复应用")
@MainActor
func legacyAutomationExecutionDoesNotReapplyAfterRestart() throws {
    let defaults = try makeEnhancementDefaults("legacyAutomationRestart")
    let firstBackend = EnhancedFakeAppVolumeBackend()
    let firstService = AppVolumeService(backend: firstBackend, userDefaults: defaults)
    firstBackend.send(candidates: [.music], output: .fixture(volume: 0.7))
    let preset = firstService.savePreset(named: "夜间", masterVolume: 0.3, appVolumes: ["com.apple.Music": 0.2])
    firstService.addAutomationRule(presetID: preset.id, outputDeviceUID: "speaker")
    let rule = try #require(firstService.automationRules.first)
    let legacyExecution = AppVolumeAutomationExecution(
        id: UUID(),
        ruleID: rule.id,
        presetID: preset.id,
        presetName: preset.name,
        outputDeviceName: "Mac 扬声器",
        outputDeviceUID: nil,
        executedAt: .now
    )
    defaults.set(
        try JSONEncoder().encode([legacyExecution]),
        forKey: "appVolume.automationExecutions.v1"
    )

    let restartedBackend = EnhancedFakeAppVolumeBackend()
    let restartedService = AppVolumeService(backend: restartedBackend, userDefaults: defaults)
    restartedBackend.send(candidates: [.music], output: .fixture(volume: 0.9))

    let migratedExecution = try #require(restartedService.automationExecutions.first)
    #expect(migratedExecution.id == legacyExecution.id)
    #expect(migratedExecution.outputDeviceUID == "speaker")
    #expect(restartedService.output.volume == 0.9)
}

@Test("会议压低保存快照后中断，重启会补做未完成的压低")
@MainActor
func meetingDuckingCompletesInterruptedApplicationAfterRestart() throws {
    let defaults = try makeEnhancementDefaults("meetingDuckingInterrupted")
    let firstBackend = EnhancedFakeAppVolumeBackend()
    let firstService = AppVolumeService(backend: firstBackend, userDefaults: defaults)
    firstService.setEnabled(true)
    firstService.setMeetingDuckingEnabled(true)
    firstService.setMeetingDuckingFactor(0.4)
    var stateDuringFirstApply: InterruptedDuckingState?
    firstBackend.onApply = { _, _ in
        guard stateDuringFirstApply == nil else { return }
        guard let data = defaults.data(forKey: "appVolume.duckedVolumes.v1"),
              let values = try? JSONDecoder().decode([String: InterruptedDuckingState].self, from: data) else {
            return
        }
        stateDuringFirstApply = values["com.apple.Music"]
    }
    firstBackend.send(candidates: [.music, .zoom])
    #expect(stateDuringFirstApply == InterruptedDuckingState(
        originalVolume: 1,
        duckedVolume: 0.4,
        needsDucking: true
    ))

    let restartedBackend = EnhancedFakeAppVolumeBackend()
    let restartedService = AppVolumeService(backend: restartedBackend, userDefaults: defaults)
    restartedBackend.send(candidates: [.music, .zoom])
    #expect(restartedService.session(id: "com.apple.Music")?.volume == 0.4)

    restartedBackend.send(candidates: [.music])
    #expect(restartedService.session(id: "com.apple.Music")?.volume == 1)
}

@Test("会议 App 发声时压低其他 App，结束后恢复原音量")
@MainActor
func meetingDuckingRestoresOtherApps() throws {
    let defaults = try makeEnhancementDefaults("meetingDucking")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    service.setMeetingDuckingEnabled(true)
    service.setMeetingDuckingFactor(0.4)
    backend.send(candidates: [.music, .zoom])

    #expect(service.isMeetingDuckingActive)
    #expect(service.session(id: "com.apple.Music")?.volume == 0.4)
    backend.send(candidates: [.music])
    #expect(!service.isMeetingDuckingActive)
    #expect(service.session(id: "com.apple.Music")?.volume == 1)
}

@Test("会议进行中修改压低比例会立即按新比例重新应用")
@MainActor
func meetingDuckingFactorReappliesWhileActive() throws {
    let defaults = try makeEnhancementDefaults("meetingDuckingFactor")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    service.setMeetingDuckingEnabled(true)
    backend.send(candidates: [.music, .zoom])

    service.setMeetingDuckingFactor(0.6)

    #expect(service.isMeetingDuckingActive)
    #expect(service.session(id: "com.apple.Music")?.volume == 0.6)
}

@Test("会议中新增发声 App 会被增量压低，手动调节会作为恢复值")
@MainActor
func meetingDuckingHandlesNewAndManuallyAdjustedApps() throws {
    let defaults = try makeEnhancementDefaults("meetingDuckingIncremental")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    service.setMeetingDuckingEnabled(true)
    service.setMeetingDuckingFactor(0.4)
    backend.send(candidates: [.zoom])
    backend.send(candidates: [.zoom, .music])
    #expect(service.session(id: "com.apple.Music")?.volume == 0.4)

    service.setVolume(0.6, for: "com.apple.Music")
    backend.send(candidates: [.music])
    #expect(service.session(id: "com.apple.Music")?.volume == 0.6)
}

@Test("设备切换会应用绑定的预设")
@MainActor
func devicePresetBindingAppliesOnOutputChange() throws {
    let defaults = try makeEnhancementDefaults("devicePreset")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music], output: .fixture(deviceUID: "speaker"))
    let preset = service.savePreset(named: "耳机", masterVolume: 0.35, appVolumes: ["com.apple.Music": 0.5])
    service.bindPreset(preset.id, toOutputDeviceUID: "headphones")

    backend.send(candidates: [.music], output: .fixture(deviceUID: "headphones", deviceName: "AirPods"))

    #expect(service.boundPresetID(forOutputDeviceUID: "headphones") == preset.id)
    #expect(service.output.volume == 0.35)
    #expect(service.session(id: "com.apple.Music")?.volume == 0.5)
}

@Test("应用均衡器预设和单设备输出会持久化并参与音频路由")
@MainActor
func appEqualizerAndOutputDevicePersistAndRoute() throws {
    let defaults = try makeEnhancementDefaults("appEqualizerAndOutput")
    let backend = EnhancedFakeAppVolumeBackend()
    let speaker = AudioOutputDevice(id: 11, uid: "speaker", name: "Mac 扬声器", isDefault: true)
    let headphones = AudioOutputDevice(id: 12, uid: "headphones", name: "AirPods", isDefault: false)
    backend.outputDevices = [speaker, headphones]
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music], output: .fixture(deviceID: speaker.id, deviceUID: speaker.uid))

    service.setEnabled(true)
    service.setEqualizerPreset(.bassBoost, for: "com.apple.Music")
    service.setOutputDevice(headphones, for: "com.apple.Music")

    let session = try #require(service.session(id: "com.apple.Music"))
    #expect(session.equalizer.isEnabled)
    #expect(session.equalizer.gain(at: 0) > 0)
    #expect(session.outputDeviceUID == headphones.uid)
    #expect(backend.appliedTargets.last?.equalizer == session.equalizer)
    #expect(backend.appliedTargets.last?.outputDeviceUID == headphones.uid)

    let restoredBackend = EnhancedFakeAppVolumeBackend()
    let restored = AppVolumeService(backend: restoredBackend, userDefaults: defaults)
    restoredBackend.send(candidates: [.music], output: .fixture(deviceID: speaker.id, deviceUID: speaker.uid))
    let restoredSession = try #require(restored.session(id: "com.apple.Music"))
    #expect(restoredSession.equalizer == session.equalizer)
    #expect(restoredSession.outputDeviceUID == headphones.uid)
}

@MainActor
private final class EnhancedFakeAppVolumeBackend: AppVolumeRoutingBackend {
    var onSnapshot: ((AppVolumeBackendSnapshot) -> Void)?
    var outputDevices: [AudioOutputDevice] = []
    var selectedOutputIDs: [AudioDeviceID] = []
    var masterVolumes: [Double] = []
    var inputVolumes: [Double] = []
    var inputMutedStates: [Bool] = []
    var applyError: AppVolumeRoutingError?
    var applied: [(id: String, volume: Double)] = []
    var appliedTargets: [AppVolumeTarget] = []
    var onApply: ((String, Double) -> Void)?
    private var currentOutput = SystemOutputVolumeState.fixture()
    private var currentInput = SystemInputVolumeState.unavailable
    private var currentCandidates: [AppAudioProcessCandidate] = []

    func start() {}
    func stop() {}
    func apply(volume: Double, to target: AppVolumeTarget) throws {
        if let applyError { throw applyError }
        applied.append((target.rootBundleID, volume))
        appliedTargets.append(target)
        onApply?(target.rootBundleID, volume)
    }
    func removeRoute(for rootBundleID: String) {}
    func setMasterVolume(_ volume: Double) throws {
        masterVolumes.append(volume)
        currentOutput.volume = volume
        onSnapshot?(AppVolumeBackendSnapshot(candidates: currentCandidates, output: currentOutput, input: currentInput))
    }
    func setMasterMuted(_ muted: Bool) throws {
        currentOutput.isMuted = muted
    }
    func availableOutputDevices() throws -> [AudioOutputDevice] { outputDevices }
    func selectOutputDevice(_ device: AudioOutputDevice) throws {
        selectedOutputIDs.append(device.id)
        currentOutput = .fixture(deviceID: device.id, deviceUID: device.uid, deviceName: device.name)
        onSnapshot?(AppVolumeBackendSnapshot(candidates: currentCandidates, output: currentOutput, input: currentInput))
    }
    func setInputVolume(_ volume: Double) throws {
        inputVolumes.append(volume)
        currentInput.volume = volume
    }
    func setInputMuted(_ muted: Bool) throws {
        inputMutedStates.append(muted)
        currentInput.isMuted = muted
    }
    func send(
        candidates: [AppAudioProcessCandidate] = [],
        output: SystemOutputVolumeState = .fixture(),
        input: SystemInputVolumeState = .unavailable
    ) {
        currentCandidates = candidates
        currentOutput = output
        currentInput = input
        onSnapshot?(AppVolumeBackendSnapshot(candidates: candidates, output: output, input: input))
    }
}

private extension AppAudioProcessCandidate {
    static let music = AppAudioProcessCandidate(
        processObjectID: 20,
        processID: 200,
        audioBundleID: "com.apple.Music",
        rootBundleID: "com.apple.Music",
        displayName: "音乐",
        bundleURL: URL(fileURLWithPath: "/System/Applications/Music.app"),
        isRunningOutput: true
    )

    static let podcasts = AppAudioProcessCandidate(
        processObjectID: 21,
        processID: 201,
        audioBundleID: "com.apple.podcasts",
        rootBundleID: "com.apple.podcasts",
        displayName: "播客",
        bundleURL: URL(fileURLWithPath: "/System/Applications/Podcasts.app"),
        isRunningOutput: true
    )

    static let zoom = AppAudioProcessCandidate(
        processObjectID: 22,
        processID: 202,
        audioBundleID: "us.zoom.xos",
        rootBundleID: "us.zoom.xos",
        displayName: "Zoom",
        bundleURL: URL(fileURLWithPath: "/Applications/zoom.us.app"),
        isRunningOutput: true
    )
}

private extension SystemOutputVolumeState {
    static func fixture(
        deviceID: AudioDeviceID = 99,
        deviceUID: String = "speaker",
        deviceName: String = "Mac 扬声器",
        volume: Double = 0.5
    ) -> Self {
        Self(
            deviceID: deviceID,
            deviceUID: deviceUID,
            deviceName: deviceName,
            volume: volume,
            isMuted: false,
            canSetVolume: true,
            canSetMute: true
        )
    }
}

private extension SystemInputVolumeState {
    static let fixture = Self(
        deviceID: 88,
        deviceName: "Mac 麦克风",
        volume: 0.4,
        isMuted: false,
        canSetVolume: true,
        canSetMute: true
    )
}

private struct LegacyAppVolumeProfile: Codable {
    var rootBundleID: String
    var displayName: String
    var bundleURL: URL?
    var volume: Double
    var lastNonzeroVolume: Double
    var audioBundleIDs: Set<String>
    var lastAdjustedAt: Date
}

private struct InterruptedDuckingState: Codable, Equatable {
    var originalVolume: Double
    var duckedVolume: Double
    var needsDucking: Bool
}

private func makeEnhancementDefaults(_ name: String) throws -> UserDefaults {
    let suiteName = "AppVolumeEnhancementsTests.\(name).\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
