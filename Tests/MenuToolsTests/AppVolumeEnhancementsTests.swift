import CoreAudio
import Synchronization
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
    // 1.5 倍增强会限幅在 ±1
    #expect(AppVolumeGainRamp.clamped(1.5) == 1)
    #expect(AppVolumeGainRamp.clamped(-1.5) == -1)
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
        input: SystemInputVolumeState = .unavailable,
        levels: [String: AppVolumeMeter] = [:]
    ) {
        currentCandidates = candidates
        currentOutput = output
        currentInput = input
        onSnapshot?(AppVolumeBackendSnapshot(
            candidates: candidates,
            output: output,
            input: input,
            levels: levels
        ))
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
    static let fixture = fixture()

    static func fixture(
        deviceID: AudioDeviceID = 88,
        deviceUID: String = "built-in-mic",
        deviceName: String = "Mac 麦克风",
        volume: Double = 0.4,
        isMuted: Bool = false
    ) -> Self {
        Self(
            deviceID: deviceID,
            deviceUID: deviceUID,
            deviceName: deviceName,
            volume: volume,
            isMuted: isMuted,
            canSetVolume: true,
            canSetMute: true
        )
    }
}

extension SystemInputVolumeState {
    /// 纯函数测试用的构造入口（只关心设备与值）。
    fileprivate static func inputFixture(
        deviceUID: String,
        volume: Double,
        isMuted: Bool
    ) -> Self {
        fixture(deviceUID: deviceUID, volume: volume, isMuted: isMuted)
    }
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

@MainActor
private final class FakeAppVolumeAlerter: AppVolumeAlerting {
    var events: [AppVolumeNotificationEvent] = []
    var requestedPermission = false
    var permission: AppVolumeNotificationPermission = .authorized

    func requestPermission() {
        requestedPermission = true
    }

    func currentPermission() async -> AppVolumeNotificationPermission {
        permission
    }

    func send(_ event: AppVolumeNotificationEvent) {
        events.append(event)
    }
}

private func makeEnhancementDefaults(_ name: String) throws -> UserDefaults {
    let suiteName = "AppVolumeEnhancementsTests.\(name).\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@Test("套用预设会一并恢复 EQ、输出设备、分组与收藏")
@MainActor
func presetAppliesEqualizerDeviceGroupAndFavorite() throws {
    let defaults = try makeEnhancementDefaults("presetCoverage")
    let backend = EnhancedFakeAppVolumeBackend()
    let speaker = AudioOutputDevice(id: 11, uid: "speaker", name: "Mac 扬声器", isDefault: true)
    let headphones = AudioOutputDevice(id: 12, uid: "headphones", name: "AirPods", isDefault: false)
    backend.outputDevices = [speaker, headphones]
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music, .podcasts], output: .fixture())
    service.setEnabled(true)

    service.setEqualizerPreset(.vocalClarity, for: "com.apple.Music")
    service.setOutputDevice(headphones, for: "com.apple.Music")
    service.setAppGroup(.meeting, for: "com.apple.Music")
    service.setFavorite(true, for: "com.apple.Music")
    service.setVolume(0.42, for: "com.apple.Music")

    let preset = service.savePreset(named: "会议", appVolumes: ["com.apple.Music": 0.42])

    #expect(preset.schemaVersion == AppVolumePreset.currentSchemaVersion)
    #expect(!preset.needsCoverageUpgrade)
    let stored = try #require(preset.appSettings["com.apple.Music"])
    #expect(stored.equalizer.gains == AppVolumeEqualizerPreset.vocalClarity.gains)
    #expect(stored.outputDeviceUID == "headphones")
    #expect(stored.appGroup == .meeting)
    #expect(stored.isFavorite)

    service.setEqualizerPreset(.flat, for: "com.apple.Music")
    service.setOutputDevice(nil, for: "com.apple.Music")
    service.setAppGroup(.other, for: "com.apple.Music")
    service.setFavorite(false, for: "com.apple.Music")

    service.applyPreset(id: preset.id)

    let session = try #require(service.session(id: "com.apple.Music"))
    #expect(session.equalizer.isEnabled)
    #expect(session.equalizer.gains == AppVolumeEqualizerPreset.vocalClarity.gains)
    #expect(session.outputDeviceUID == "headphones")
    #expect(session.appGroup == .meeting)
    #expect(session.isFavorite)
}

@Test("导入的 v1 预设套用后只改音量，不动 EQ")
@MainActor
func legacyPresetAppliesVolumeOnly() throws {
    let defaults = try makeEnhancementDefaults("legacyPreset")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music], output: .fixture())
    service.setEnabled(true)

    // 旧版本导出的归档：只有 masterVolume 与 appVolumes，没有 appSettings
    let legacyArchive = """
    {
      "version": 1,
      "presets": [{
        "id": "6B29FC40-CA47-1067-B31D-00DD010662DA",
        "name": "旧预设",
        "masterVolume": 0.5,
        "appVolumes": { "com.apple.Music": 0.3 },
        "createdAt": 760000000
      }],
      "automationRules": []
    }
    """
    try service.importPresets(from: Data(legacyArchive.utf8))
    let legacy = try #require(service.presets.first)
    #expect(legacy.needsCoverageUpgrade)
    #expect(legacy.appSettings.isEmpty)

    service.setEqualizerPreset(.trebleBoost, for: "com.apple.Music")
    service.applyPreset(id: legacy.id)

    let session = try #require(service.session(id: "com.apple.Music"))
    // 音量被套用，EQ 保持原样
    #expect(abs(session.volume - 0.3) < 0.001)
    #expect(session.equalizer.gains == AppVolumeEqualizerPreset.trebleBoost.gains)
}

@Test("自定义 EQ 预设可保存、套用、重命名并持久化")
@MainActor
func customEqualizerLibraryPersistsAndApplies() throws {
    let defaults = try makeEnhancementDefaults("customEqualizer")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music], output: .fixture())
    service.setEnabled(true)

    let preset = service.saveCustomEqualizer(named: "深夜", gains: AppVolumeEqualizerPreset.lateNight.gains)
    #expect(service.customEqualizers.count == 1)
    #expect(preset.name == "深夜")
    #expect(preset.gains == AppVolumeEqualizerPreset.lateNight.gains)

    service.applyCustomEqualizer(id: preset.id, to: "com.apple.Music")
    let session = try #require(service.session(id: "com.apple.Music"))
    #expect(session.equalizer.isEnabled)
    #expect(session.equalizer.gains == AppVolumeEqualizerPreset.lateNight.gains)

    service.updateCustomEqualizer(id: preset.id, named: "更深夜")
    #expect(service.customEqualizers.first?.name == "更深夜")

    let restored = AppVolumeService(backend: EnhancedFakeAppVolumeBackend(), userDefaults: defaults)
    #expect(restored.customEqualizers.count == 1)
    #expect(restored.customEqualizers.first?.name == "更深夜")
    #expect(restored.customEqualizers.first?.gains == AppVolumeEqualizerPreset.lateNight.gains)

    service.deleteCustomEqualizer(id: preset.id)
    #expect(service.customEqualizers.isEmpty)
}

@Test("从当前 App 曲线保存自定义 EQ 预设")
@MainActor
func customEqualizerCapturesAppCurve() throws {
    let defaults = try makeEnhancementDefaults("captureCurve")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.podcasts], output: .fixture())
    service.setEnabled(true)
    service.setEqualizerPreset(.podcast, for: "com.apple.podcasts")

    let preset = try #require(service.saveCurrentEqualizerAsCustom(named: "播客", for: "com.apple.podcasts"))

    #expect(preset.gains == AppVolumeEqualizerPreset.podcast.gains)
    #expect(service.customEqualizers.map(\.name) == ["播客"])
}

@Test("预设导出包含自定义 EQ，导入端能读回")
@MainActor
func presetExportIncludesCustomEqualizers() throws {
    let defaults = try makeEnhancementDefaults("archiveV2")
    let service = AppVolumeService(backend: EnhancedFakeAppVolumeBackend(), userDefaults: defaults)
    _ = service.saveCustomEqualizer(named: "夜间", gains: AppVolumeEqualizerPreset.lateNight.gains)

    let data = try #require(service.exportPresets())
    let archive = try JSONDecoder().decode(AppVolumePresetArchive.self, from: data)
    #expect(archive.version == AppVolumePresetArchive.currentVersion)
    #expect(archive.equalizerPresets.count == 1)

    let target = AppVolumeService(
        backend: EnhancedFakeAppVolumeBackend(),
        userDefaults: try makeEnhancementDefaults("archiveV2Target")
    )
    try target.importPresets(from: data)

    #expect(target.customEqualizers.count == 1)
    #expect(target.customEqualizers.first?.gains == AppVolumeEqualizerPreset.lateNight.gains)
}

@Test("声像与单声道会进入路由目标，单独设置也会建立路由")
@MainActor
func panAndMonoReachRoutingTarget() throws {
    let defaults = try makeEnhancementDefaults("panMono")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music], output: .fixture())
    service.setEnabled(true)

    // 音量保持 100%，只有声像改变也应该建立路由
    service.setPan(-1, for: "com.apple.Music")
    var target = try #require(backend.appliedTargets.last)
    #expect(target.pan == -1)
    #expect(!target.isMono)

    service.setPan(0.25, for: "com.apple.Music")
    service.setMono(true, for: "com.apple.Music")
    target = try #require(backend.appliedTargets.last)
    #expect(abs(target.pan - 0.25) < 0.0001)
    #expect(target.isMono)

    let session = try #require(service.session(id: "com.apple.Music"))
    #expect(session.pan == 0.25)
    #expect(session.isMono)

    // 恢复默认后不需要路由（被视为旁路）
    service.setPan(0, for: "com.apple.Music")
    service.setMono(false, for: "com.apple.Music")
    #expect(service.session(id: "com.apple.Music")?.routeStatus == .bypassed)
}

@Test("预设会保存并恢复声像与单声道")
@MainActor
func presetRoundTripsPanAndMono() throws {
    let defaults = try makeEnhancementDefaults("presetPanMono")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music], output: .fixture())
    service.setEnabled(true)

    service.setPan(0.8, for: "com.apple.Music")
    service.setMono(true, for: "com.apple.Music")
    let preset = service.savePreset(named: "单声道", appVolumes: ["com.apple.Music": 1])

    let settings = try #require(preset.appSettings["com.apple.Music"])
    #expect(abs(settings.pan - 0.8) < 0.0001)
    #expect(settings.isMono)

    service.setPan(-0.5, for: "com.apple.Music")
    service.setMono(false, for: "com.apple.Music")
    service.applyPreset(id: preset.id)

    let session = try #require(service.session(id: "com.apple.Music"))
    #expect(abs(session.pan - 0.8) < 0.0001)
    #expect(session.isMono)
}

@Test("菜单栏显示模式会持久化，最响 App 取正在发声里音量最高的")
@MainActor
func menuBarDisplayModePersistsAndPicksLoudestApp() throws {
    let defaults = try makeEnhancementDefaults("menuBarMode")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music, .podcasts], output: .fixture())
    service.setEnabled(true)

    service.setVolume(0.30, for: "com.apple.Music")
    service.setVolume(0.70, for: "com.apple.podcasts")

    let loudest = try #require(service.loudestActiveApp)
    #expect(loudest.name == "播客")
    #expect(abs(loudest.volume - 0.70) < 0.001)

    // 模式变化会通知菜单栏刷新
    let notified = Atomic(false)
    let token = NotificationCenter.default.addObserver(
        forName: .appVolumeDidChange,
        object: service,
        queue: nil
    ) { _ in
        notified.store(true, ordering: .relaxed)
    }
    service.setMenuBarDisplayMode(.master)
    NotificationCenter.default.removeObserver(token)
    let didNotify = notified.load(ordering: .relaxed)
    #expect(didNotify)

    let restored = AppVolumeService(backend: EnhancedFakeAppVolumeBackend(), userDefaults: defaults)
    #expect(restored.menuBarDisplayMode == .master)

    // 没有正在发声的 App 时返回 nil
    backend.send(candidates: [], output: .fixture())
    let idleLoudest = service.loudestActiveApp
    #expect(idleLoudest == nil)
}

@Test("自动化套用预设会一并恢复 EQ，撤销能回到执行前的曲线")
@MainActor
func automationAppliesPresetCoverageAndUndoRestoresIt() throws {
    let defaults = try makeEnhancementDefaults("automationCoverage")
    let backend = EnhancedFakeAppVolumeBackend()
    let headphones = AudioOutputDevice(id: 12, uid: "headphones", name: "AirPods", isDefault: true)
    backend.outputDevices = [headphones]
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music], output: .fixture(deviceID: headphones.id, deviceUID: headphones.uid))
    service.setEnabled(true)

    // 预设里记录 EQ，然后切回另一条曲线
    service.setEqualizerPreset(.vocalClarity, for: "com.apple.Music")
    let preset = service.savePreset(named: "通勤", masterVolume: 0.3, appVolumes: ["com.apple.Music": 0.5])
    service.setEqualizerPreset(.bassBoost, for: "com.apple.Music")

    service.addAutomationRule(presetID: preset.id, outputDeviceUID: headphones.uid)
    service.evaluateAutomation(now: Date(timeIntervalSince1970: 1_800_000_000))

    var session = try #require(service.session(id: "com.apple.Music"))
    #expect(session.equalizer.gains == AppVolumeEqualizerPreset.vocalClarity.gains)
    #expect(abs(session.volume - 0.5) < 0.001)

    // 撤销回到自动化执行前的曲线
    service.undoLatestAutomation()
    session = try #require(service.session(id: "com.apple.Music"))
    #expect(session.equalizer.gains == AppVolumeEqualizerPreset.bassBoost.gains)
}

@Test("削波按开关推送并遵守冷却，首次启用会申请权限")
@MainActor
func clippingNotificationsRespectSwitchAndCooldown() throws {
    let defaults = try makeEnhancementDefaults("clippingNotification")
    let backend = EnhancedFakeAppVolumeBackend()
    let alerter = FakeAppVolumeAlerter()
    let service = AppVolumeService(backend: backend, userDefaults: defaults, alerter: alerter)
    backend.send(candidates: [.music], output: .fixture())
    service.setEnabled(true)
    service.setVolume(0.5, for: "com.apple.Music")

    let clippingLevels = [
        "com.apple.Music": AppVolumeMeter(peak: 1, rms: 1, heldPeak: 1, isClipping: true, cpuLoad: 0.1)
    ]

    // 关闭时不推送
    service.setNotificationEnabled(false, for: .clipping)
    backend.send(candidates: [.music], output: .fixture(), levels: clippingLevels)
    #expect(alerter.events.isEmpty)

    // 重新打开会申请权限并推送一次
    service.setNotificationEnabled(true, for: .clipping)
    #expect(alerter.requestedPermission)
    backend.send(candidates: [.music], output: .fixture(), levels: clippingLevels)
    #expect(alerter.events.count == 1)
    guard case let .clipping(appName, appID) = alerter.events.first else {
        Issue.record("期望收到削波通知")
        return
    }
    #expect(appName == "音乐")
    #expect(appID == "com.apple.Music")

    // 冷却期内重复削波不再推送
    backend.send(candidates: [.music], output: .fixture(), levels: clippingLevels)
    #expect(alerter.events.count == 1)
}

@Test("自动化提醒默认关闭，打开后套用预设会推送一次")
@MainActor
func automationNotificationFollowsSwitch() throws {
    let defaults = try makeEnhancementDefaults("automationNotification")
    let backend = EnhancedFakeAppVolumeBackend()
    let headphones = AudioOutputDevice(id: 12, uid: "headphones", name: "AirPods", isDefault: true)
    backend.outputDevices = [headphones]
    let alerter = FakeAppVolumeAlerter()
    let service = AppVolumeService(backend: backend, userDefaults: defaults, alerter: alerter)
    backend.send(candidates: [.music], output: .fixture(deviceID: headphones.id, deviceUID: headphones.uid))

    let preset = service.savePreset(named: "通勤", masterVolume: 0.3, appVolumes: ["com.apple.Music": 0.5])
    service.addAutomationRule(presetID: preset.id, outputDeviceUID: headphones.uid)

    service.evaluateAutomation(now: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(alerter.events.isEmpty)  // 默认关闭

    service.setNotificationEnabled(true, for: .automation)
    service.evaluateAutomation(now: Date(timeIntervalSince1970: 1_800_100_000))
    #expect(alerter.events.count == 1)
    guard case let .automation(presetName) = alerter.events.first else {
        Issue.record("期望收到自动化通知")
        return
    }
    #expect(presetName == "通勤")
}

@Test("长时间高音量会推送听力保护通知")
@MainActor
func hearingProtectionNotificationFires() throws {
    let defaults = try makeEnhancementDefaults("hearingNotification")
    let backend = EnhancedFakeAppVolumeBackend()
    let alerter = FakeAppVolumeAlerter()
    let service = AppVolumeService(backend: backend, userDefaults: defaults, alerter: alerter)
    backend.send(candidates: [.music], output: .fixture(volume: 0.9))
    service.setNotificationEnabled(true, for: .hearingProtection)

    var now = Date(timeIntervalSince1970: 1_800_000_000)
    service.recordHearingExposure(now: now)
    for _ in 0..<800 {
        now = now.addingTimeInterval(5)
        service.recordHearingExposure(now: now)
    }

    #expect(service.hearingWarningMessage != nil)
    #expect(alerter.events.contains { $0.kind == .hearingProtection })
}

@Test("输入电平监控停止后会恢复监控前的输入音量与静音")
@MainActor
func inputLevelMonitoringRestoresInputState() throws {
    let defaults = try makeEnhancementDefaults("inputLevelRestore")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    service.start()
    backend.send(candidates: [.music], output: .fixture(), input: .fixture)
    service.setEnabled(true)

    service.startInputLevelMonitoring()
    // 监控期间蓝牙耳机切到通话档位：音量被系统改成 0.9、静音被解除
    backend.send(
        candidates: [.music],
        output: .fixture(),
        input: .fixture(volume: 0.9, isMuted: false)
    )
    #expect(abs(service.input.volume - 0.9) < 0.001)

    service.stopInputLevelMonitoring()

    #expect(backend.inputVolumes.last == 0.4)
    #expect(abs(service.input.volume - 0.4) < 0.001)
    #expect(service.input.peakLevel == 0)
}

@Test("监控期间输入音量没变就不会多余写入")
@MainActor
func inputLevelMonitoringSkipsRestoreWhenUnchanged() throws {
    let defaults = try makeEnhancementDefaults("inputLevelUnchanged")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    service.start()
    backend.send(candidates: [.music], output: .fixture(), input: .fixture)
    service.setEnabled(true)

    service.startInputLevelMonitoring()
    service.stopInputLevelMonitoring()

    #expect(backend.inputVolumes.isEmpty)
    #expect(backend.inputMutedStates.isEmpty)
}

@Test("监控期间换到别的输入设备时不会把音量写到新设备")
@MainActor
func inputLevelMonitoringDoesNotTouchOtherDevice() throws {
    let defaults = try makeEnhancementDefaults("inputLevelOtherDevice")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    service.start()
    backend.send(candidates: [.music], output: .fixture(), input: .fixture)
    service.setEnabled(true)

    service.startInputLevelMonitoring()
    // 设备被拔掉，系统改用另一台麦克风（音量不同）
    backend.send(
        candidates: [.music],
        output: .fixture(),
        input: .fixture(deviceUID: "other-mic", deviceName: "Mac 麦克风", volume: 0.7)
    )
    service.stopInputLevelMonitoring()

    #expect(backend.inputVolumes.isEmpty)
    #expect(abs(service.input.volume - 0.7) < 0.001)
}

@Test("输入监控恢复策略：设备一致且值有变化才恢复")
func inputLevelRestorePolicy() {
    let captured = AppVolumeInputLevelRestore(deviceUID: "wh-1000xm3", volume: 0.553, isMuted: false)

    let changed = captured.restoration(for: .inputFixture(deviceUID: "wh-1000xm3", volume: 0.9, isMuted: true))
    #expect(changed?.volume == 0.553)
    #expect(changed?.isMuted == false)

    let unchanged = captured.restoration(for: .inputFixture(deviceUID: "wh-1000xm3", volume: 0.553, isMuted: false))
    #expect(unchanged == nil)

    let otherDevice = captured.restoration(for: .inputFixture(deviceUID: "other-mic", volume: 0.9, isMuted: false))
    #expect(otherDevice == nil)

    let missingCapture = AppVolumeInputLevelRestore(deviceUID: "", volume: 1, isMuted: false)
    #expect(missingCapture.restoration(for: .inputFixture(deviceUID: "wh-1000xm3", volume: 0.2, isMuted: false)) == nil)
}

@Test("蓝牙切回档位后改写音量时，补校验会再恢复一次")
@MainActor
func inputLevelRestoreVerificationReappliesValue() throws {
    let defaults = try makeEnhancementDefaults("inputLevelVerify")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    service.start()
    backend.send(candidates: [.music], output: .fixture(), input: .fixture)
    service.setEnabled(true)

    let captured = AppVolumeInputLevelRestore(deviceUID: "built-in-mic", volume: 0.4, isMuted: false)
    // 系统在切档位时又改了一次音量
    backend.send(candidates: [.music], output: .fixture(), input: .fixture(volume: 0.85))

    let didWrite = service.applyInputRestore(captured)

    #expect(didWrite)
    #expect(backend.inputVolumes.last == 0.4)
    #expect(abs(service.input.volume - 0.4) < 0.001)

    // 已经一致时不再写入
    let secondWrite = service.applyInputRestore(captured)
    #expect(!secondWrite)
}

/// 共享文件的内存实现：两台"设备"共用同一个实例。
private final class InMemorySharedFile: SharedFileStoring, @unchecked Sendable {
    private var contents: Data?
    func read(at url: URL) throws -> Data? { contents }
    func write(_ data: Data, to url: URL) throws { contents = data }
}

private final class InMemoryPresetSyncPassphraseStore: AppVolumePresetSyncPassphraseStoring, @unchecked Sendable {
    private var value: String?
    func passphrase() -> String? { value }
    func save(_ passphrase: String) { value = passphrase }
    func clear() { value = nil }
}

@Test("两台设备经共享文件同步：并集、较新者胜出、删除靠墓碑传播")
@MainActor
func presetSyncAcrossTwoDevices() throws {
    let sharedFile = InMemorySharedFile()
    let url = URL(fileURLWithPath: "/tmp/mt-volume-presets.mtvolsync")

    let defaultsA = try makeEnhancementDefaults("syncDeviceA")
    let defaultsB = try makeEnhancementDefaults("syncDeviceB")
    let serviceA = AppVolumeService(backend: EnhancedFakeAppVolumeBackend(), userDefaults: defaultsA)
    let serviceB = AppVolumeService(backend: EnhancedFakeAppVolumeBackend(), userDefaults: defaultsB)
    let syncA = AppVolumePresetSyncService(
        userDefaults: defaultsA,
        appVolume: serviceA,
        passphraseStore: InMemoryPresetSyncPassphraseStore(),
        fileStore: sharedFile
    )
    let syncB = AppVolumePresetSyncService(
        userDefaults: defaultsB,
        appVolume: serviceB,
        passphraseStore: InMemoryPresetSyncPassphraseStore(),
        fileStore: sharedFile
    )
    syncA.setFileURL(url)
    syncB.setFileURL(url)

    // A 保存预设并写入共享文件，B 同步后拿到
    let presetA = serviceA.savePreset(named: "通勤", masterVolume: 0.3, appVolumes: ["com.apple.Music": 0.5])
    #expect(syncA.synchronize(passphrase: "口令"))
    #expect(syncB.synchronize(passphrase: "口令"))
    #expect(serviceB.presets.map(\.name) == ["通勤"])

    // B 新增自定义 EQ，A 同步后拿到
    _ = serviceB.saveCustomEqualizer(named: "夜间", gains: AppVolumeEqualizerPreset.lateNight.gains)
    #expect(syncB.synchronize(passphrase: "口令"))
    #expect(syncA.synchronize(passphrase: "口令"))
    #expect(serviceA.customEqualizers.map(\.name) == ["夜间"])
    #expect(serviceA.presets.count == 1)

    // B 删除预设并同步，A 同步后同样删除（墓碑传播）
    serviceB.deletePreset(id: presetA.id)
    #expect(syncB.synchronize(passphrase: "口令"))
    #expect(syncA.synchronize(passphrase: "口令"))
    #expect(serviceA.presets.isEmpty)
    #expect(serviceA.presetTombstones[presetA.id] != nil)
}

@Test("口令错误时同步失败并给出原因，不会改动本机预设")
@MainActor
func presetSyncReportsWrongPassphrase() throws {
    let sharedFile = InMemorySharedFile()
    let url = URL(fileURLWithPath: "/tmp/mt-volume-presets-wrong.mtvolsync")
    let defaultsA = try makeEnhancementDefaults("syncWrongA")
    let defaultsB = try makeEnhancementDefaults("syncWrongB")
    let serviceA = AppVolumeService(backend: EnhancedFakeAppVolumeBackend(), userDefaults: defaultsA)
    let serviceB = AppVolumeService(backend: EnhancedFakeAppVolumeBackend(), userDefaults: defaultsB)
    let syncA = AppVolumePresetSyncService(
        userDefaults: defaultsA,
        appVolume: serviceA,
        passphraseStore: InMemoryPresetSyncPassphraseStore(),
        fileStore: sharedFile
    )
    let syncB = AppVolumePresetSyncService(
        userDefaults: defaultsB,
        appVolume: serviceB,
        passphraseStore: InMemoryPresetSyncPassphraseStore(),
        fileStore: sharedFile
    )
    syncA.setFileURL(url)
    syncB.setFileURL(url)

    _ = serviceA.savePreset(named: "通勤", masterVolume: 0.3, appVolumes: ["com.apple.Music": 0.5])
    #expect(syncA.synchronize(passphrase: "正确口令"))

    let succeeded = syncB.synchronize(passphrase: "错误口令")

    #expect(!succeeded)
    #expect(syncB.lastError != nil)
    #expect(serviceB.presets.isEmpty)
}

@Test("没有共享文件夹或没有口令时同步会明确报错")
@MainActor
func presetSyncRequiresFolderAndPassphrase() throws {
    let defaults = try makeEnhancementDefaults("syncMissingConfig")
    let service = AppVolumeService(backend: EnhancedFakeAppVolumeBackend(), userDefaults: defaults)
    let sync = AppVolumePresetSyncService(
        userDefaults: defaults,
        appVolume: service,
        passphraseStore: InMemoryPresetSyncPassphraseStore(),
        fileStore: InMemorySharedFile()
    )

    #expect(!sync.synchronize(passphrase: "口令"))
    #expect(sync.lastError != nil)

    sync.setFileURL(URL(fileURLWithPath: "/tmp/mt-volume-presets-missing.mtvolsync"))
    #expect(!sync.synchronize(passphrase: "   "))
    #expect(sync.lastError != nil)

    // 开启自动同步前必须先有文件夹与已存口令
    #expect(!sync.setEnabled(true))
    sync.storePassphrase("口令")
    #expect(sync.setEnabled(true))
    #expect(sync.isEnabled)
}

@Test("墓碑保留 30 天后会被清理")
func presetTombstonesPruneAfterRetention() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fresh = UUID()
    let stale = UUID()
    let tombstones: [UUID: Date] = [
        fresh: now.addingTimeInterval(-60),
        stale: now.addingTimeInterval(-AppVolumePresetSyncMerge.tombstoneRetention - 1)
    ]

    let pruned = AppVolumePresetSyncMerge.pruned(tombstones, now: now)

    #expect(pruned[fresh] != nil)
    #expect(pruned[stale] == nil)
}

@Test("分组推子会统一组内音量，且不影响其他分组")
@MainActor
func groupVolumeAppliesToWholeGroupOnly() throws {
    let defaults = try makeEnhancementDefaults("groupVolume")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    service.start()
    backend.send(candidates: [.music, .podcasts, .zoom], output: .fixture())
    service.setEnabled(true)
    // Zoom 是会议 App，开着压低会把其他 App 音量改小，这里只验证分组推子
    service.setMeetingDuckingEnabled(false)

    // 音乐与播客属于不同分组：音乐归 meeting，播客保持默认
    service.setAppGroup(.meeting, for: "com.apple.Music")
    service.setAppGroup(.meeting, for: "us.zoom.xos")

    #expect(service.sessions(in: .meeting).count == 2)

    service.setGroupVolume(0.42, for: .meeting)

    #expect(abs((service.session(id: "com.apple.Music")?.volume ?? 0) - 0.42) < 0.001)
    #expect(abs((service.session(id: "us.zoom.xos")?.volume ?? 0) - 0.42) < 0.001)
    // 其他分组不受影响
    #expect(abs((service.session(id: "com.apple.podcasts")?.volume ?? 0) - 1) < 0.001)

    // 组内一致时返回该值，混用返回 nil
    #expect(service.groupVolume(.meeting) == 0.42)
    service.setVolume(0.8, for: "us.zoom.xos")
    #expect(service.groupVolume(.meeting) == nil)
    #expect(abs((service.groupAverageVolume(.meeting) ?? 0) - 0.61) < 0.01)
}

@Test("分组静音与恢复使用各自上次的音量")
@MainActor
func groupMuteAndRestoreUseLastNonzeroVolume() throws {
    let defaults = try makeEnhancementDefaults("groupMute")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    service.start()
    backend.send(candidates: [.music, .zoom], output: .fixture())
    service.setEnabled(true)
    service.setMeetingDuckingEnabled(false)
    service.setAppGroup(.meeting, for: "com.apple.Music")
    service.setAppGroup(.meeting, for: "us.zoom.xos")

    service.setVolume(0.3, for: "com.apple.Music")
    service.setVolume(0.7, for: "us.zoom.xos")
    service.muteGroup(.meeting)

    #expect(service.isGroupMuted(.meeting))
    #expect(service.session(id: "com.apple.Music")?.volume == 0)

    service.restoreGroup(.meeting)

    #expect(!service.isGroupMuted(.meeting))
    #expect(abs((service.session(id: "com.apple.Music")?.volume ?? 0) - 0.3) < 0.001)
    #expect(abs((service.session(id: "us.zoom.xos")?.volume ?? 0) - 0.7) < 0.001)
}

@Test("空分组的推子状态为空且不会写入")
@MainActor
func emptyGroupHasNoVolumeState() throws {
    let defaults = try makeEnhancementDefaults("groupEmpty")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    service.start()
    backend.send(candidates: [.music], output: .fixture())
    service.setEnabled(true)

    #expect(service.sessions(in: .game).isEmpty)
    #expect(service.groupVolume(.game) == nil)
    #expect(service.groupAverageVolume(.game) == nil)
    #expect(!service.isGroupMuted(.game))

    service.setGroupVolume(0.5, for: .game)
    #expect(abs((service.session(id: "com.apple.Music")?.volume ?? 0) - 1) < 0.001)
}

@Test("声道测试音长度、峰值与淡入淡出符合预期")
func channelTestToneShape() {
    let samples = AppVolumeTestTone.samples(frequency: 440, duration: 0.5, sampleRate: 48_000, amplitude: 0.25)

    #expect(samples.count == 24_000)
    let peak = samples.map { abs($0) }.max() ?? 0
    #expect(abs(peak - 0.25) < 0.01)
    // 首尾淡入淡出，避免爆音
    #expect(abs(samples[0]) < 0.001)
    #expect(abs(samples[samples.count - 1]) < 0.001)

    // 440Hz 在 0.5 秒内应有约 440 次过零
    var crossings = 0
    for index in 1 ..< samples.count where (samples[index - 1] < 0) != (samples[index] < 0) {
        crossings += 1
    }
    #expect(abs(crossings - 440) <= 2)
}

@Test("声道测试音会限制幅度上限并处理非法参数")
func channelTestToneClampsAmplitude() {
    // 超过上限会被夹住
    let loud = AppVolumeTestTone.samples(duration: 0.1, sampleRate: 8_000, amplitude: 99)
    let loudPeak = Double(loud.map { abs($0) }.max() ?? 0)
    #expect(loudPeak <= AppVolumeTestTone.maximumAmplitude + 0.001)

    #expect(AppVolumeTestTone.normalizedAmplitude(.nan) == AppVolumeTestTone.defaultAmplitude)
    #expect(AppVolumeTestTone.normalizedAmplitude(-1) == 0.01)

    // 非法时长/采样率不会产生空数组或崩溃
    #expect(AppVolumeTestTone.samples(duration: 0, sampleRate: 48_000).isEmpty == false)
    #expect(AppVolumeTestTone.samples(frequency: .nan, duration: 0.1, sampleRate: 8_000).isEmpty == false)
}

@Test("声道测试的三个声道各自映射到正确声像与文案键")
func channelTestChannelsMapToPan() {
    #expect(AppVolumeChannelTester.Channel.allCases.count == 3)
    #expect(AppVolumeChannelTester.Channel.left.pan == -1)
    #expect(AppVolumeChannelTester.Channel.right.pan == 1)
    #expect(AppVolumeChannelTester.Channel.both.pan == 0)
    for channel in AppVolumeChannelTester.Channel.allCases {
        #expect(!channel.titleKey.isEmpty)
    }
}

private func selfCheckSteps(
    permission: AppVolumePermissionState = .authorized,
    outputReady: Bool = true,
    inputReady: Bool = true,
    active: Int = 1,
    routed: Int = 1,
    failed: Int = 0,
    hasError: Bool = false
) -> [AppVolumeSelfCheckStep] {
    AppVolumeSelfCheck.steps(
        permission: permission,
        outputReady: outputReady,
        inputReady: inputReady,
        activeSessions: active,
        routedSessions: routed,
        failedSessions: failed,
        hasError: hasError
    )
}

@Test("自检在一切正常时全部通过，顺序为权限→输出→输入→路由→错误")
func selfCheckReportsAllClear() {
    let steps = selfCheckSteps()

    #expect(steps.map(\.kind) == [.permission, .output, .input, .routing, .errors])
    #expect(steps.allSatisfy { $0.status == .pass })
    #expect(steps.allSatisfy { !$0.detail.isEmpty })
    #expect(steps.map(\.id).count == Set(steps.map(\.id)).count)
}

@Test("权限被拒与没有输出设备会判为失败")
func selfCheckFailsOnPermissionAndOutput() {
    let denied = selfCheckSteps(permission: .denied)
    #expect(denied.first?.status == .failure)

    let noOutput = selfCheckSteps(outputReady: false)
    #expect(noOutput.first { $0.kind == .output }?.status == .failure)

    // 尚未申请权限只是提醒，不是失败
    let notRequested = selfCheckSteps(permission: .notRequested)
    #expect(notRequested.first?.status == .warning)
}

@Test("没有麦克风、没有 App 发声、路由失败与有错误各自给出对应结论")
func selfCheckReportsWarningsAndRoutingFailures() {
    let noInput = selfCheckSteps(inputReady: false)
    #expect(noInput.first { $0.kind == .input }?.status == .warning)

    let idle = selfCheckSteps(active: 0, routed: 0)
    #expect(idle.first { $0.kind == .routing }?.status == .warning)

    let failedRoutes = selfCheckSteps(active: 2, routed: 1, failed: 1)
    #expect(failedRoutes.first { $0.kind == .routing }?.status == .failure)

    let quiet = selfCheckSteps(active: 1, routed: 0)
    #expect(quiet.first { $0.kind == .routing }?.status == .pass)

    let withError = selfCheckSteps(hasError: true)
    #expect(withError.last?.status == .warning)
}

@Test("服务能根据当前状态给出自检步骤")
@MainActor
func serviceExposesSelfChecks() throws {
    let defaults = try makeEnhancementDefaults("selfCheck")
    let backend = EnhancedFakeAppVolumeBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    service.start()
    backend.send(candidates: [.music], output: .fixture())
    service.setEnabled(true)
    service.setVolume(0.5, for: "com.apple.Music")

    let steps = service.selfCheckSteps

    #expect(steps.count == AppVolumeSelfCheckStep.Kind.allCases.count)
    #expect(steps.first { $0.kind == .output }?.status == .pass)
    #expect(steps.first { $0.kind == .routing }?.status == .pass)
    // 没有任何错误时最后一步是 pass
    #expect(steps.last?.status == .pass)
}
