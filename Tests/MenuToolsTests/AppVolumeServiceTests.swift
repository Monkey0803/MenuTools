import Foundation
import Testing
@testable import MenuTools

@Test("实时电平采样会返回各声道样本的最大绝对值")
func inputLevelSamplingFindsPeakAmplitude() {
    let samples: [Float] = [-0.12, 0.71, -0.93, 0.45]

    let peakLevel = samples.withUnsafeBufferPointer {
        InputLevelSampling.peakLevel(in: $0)
    }

    #expect(peakLevel == 0.93)
}

@Test("App 音量会限制在 0 到 100% 并保留上次非零值")
func appVolumeProfileNormalizesValues() {
    let profile = AppVolumeProfile(
        rootBundleID: "com.example.player",
        displayName: "Player",
        volume: 1.4,
        lastNonzeroVolume: -1,
        audioBundleIDs: ["com.example.player.helper"],
        lastAdjustedAt: .distantPast
    ).normalized()

    #expect(profile.volume == 1)
    #expect(profile.lastNonzeroVolume == 1)
}

@Test("增益渐变在一个缓冲区内平滑推进到目标值")
func gainRampReachesTargetWithinBuffer() {
    let step = AppVolumeGainRamp.step(from: 1, to: 0, frames: 4)
    #expect(step == -0.25)

    var gain: Float = 1
    var applied: [Float] = []
    for _ in 0..<4 {
        gain = AppVolumeGainRamp.advanced(gain, by: step)
        applied.append(gain)
    }

    #expect(applied == [0.75, 0.5, 0.25, 0])
    #expect(abs(gain) < 0.0001)
}

@Test("增益渐变处理零帧与相同起止值，输出限幅夹住在 ±1")
func gainRampHandlesEdgeCasesAndClamping() {
    // 帧数为 0 不能除零
    #expect(AppVolumeGainRamp.step(from: 1, to: 0, frames: 0) == 0)
    // 起止相同则步长为 0（例如常态增益或静音）
    #expect(AppVolumeGainRamp.step(from: 0.37, to: 0.37, frames: 128) == 0)
    #expect(AppVolumeGainRamp.step(from: 0, to: 0, frames: 128) == 0)

    #expect(AppVolumeGainRamp.clamped(0.37) == 0.37)
    #expect(AppVolumeGainRamp.clamped(-0.37) == -0.37)
    #expect(AppVolumeGainRamp.clamped(1.5) == 1)
    #expect(AppVolumeGainRamp.clamped(-2) == -1)
}

@Test("音频 Helper 会按主 App 合并为一个会话")
func audioHelpersAreGroupedByRootApplication() {
    let candidates = [
        AppAudioProcessCandidate(
            processObjectID: 10,
            processID: 100,
            audioBundleID: "com.google.Chrome.helper",
            rootBundleID: "com.google.Chrome",
            displayName: "Google Chrome",
            bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            isRunningOutput: true
        ),
        AppAudioProcessCandidate(
            processObjectID: 11,
            processID: 101,
            audioBundleID: "com.google.Chrome.helper",
            rootBundleID: "com.google.Chrome",
            displayName: "Google Chrome",
            bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            isRunningOutput: false
        )
    ]

    let sessions = AppAudioSession.group(candidates: candidates, profiles: [:])

    #expect(sessions.count == 1)
    #expect(sessions[0].rootBundleID == "com.google.Chrome")
    #expect(sessions[0].processObjectIDs == [10, 11])
    #expect(sessions[0].isRunningOutput)
}

@Test("未发声且未记忆的 App 不进入音量列表")
func inactiveUnrememberedAppsAreHidden() {
    var candidate = AppAudioProcessCandidate.music
    candidate.isRunningOutput = false

    let sessions = AppAudioSession.group(candidates: [candidate], profiles: [:])

    #expect(sessions.isEmpty)
}

@Test("调节正在发声的最后一项不会改变列表顺序")
@MainActor
func adjustingLastActiveAppKeepsSessionOrderStable() throws {
    let defaults = try makeVolumeDefaults("stableActiveOrder")
    let backend = FakeAppVolumeRoutingBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music, .podcasts])
    let originalOrder = service.sessions.map(\.rootBundleID)
    let lastIdentifier = try #require(originalOrder.last)

    service.setVolume(0.61, for: lastIdentifier)

    #expect(service.sessions.map(\.rootBundleID) == originalOrder)
}

@Test("低于 100% 时创建路由，恢复 100% 时旁路")
@MainActor
func appVolumeServiceRoutesOnlyAttenuatedApps() throws {
    let defaults = try makeVolumeDefaults("routing")
    let backend = FakeAppVolumeRoutingBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music])

    service.setEnabled(true)
    service.setVolume(0.37, for: "com.apple.Music")

    #expect(backend.applied.last?.id == "com.apple.Music")
    #expect(backend.applied.last?.volume == 0.37)

    service.setVolume(1, for: "com.apple.Music")

    #expect(backend.removed.last == "com.apple.Music")
}

@Test("静音后再次点击会恢复上次非零音量")
@MainActor
func appVolumeMuteRestoresPreviousLevel() throws {
    let defaults = try makeVolumeDefaults("mute")
    let backend = FakeAppVolumeRoutingBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music])
    service.setEnabled(true)
    service.setVolume(0.42, for: "com.apple.Music")

    service.toggleMute(for: "com.apple.Music")
    #expect(service.session(id: "com.apple.Music")?.volume == 0)

    service.toggleMute(for: "com.apple.Music")
    #expect(service.session(id: "com.apple.Music")?.volume == 0.42)
}

@Test("App 音量配置按 Bundle ID 持久化")
@MainActor
func appVolumeProfilesPersist() throws {
    let defaults = try makeVolumeDefaults("persistence")
    let firstBackend = FakeAppVolumeRoutingBackend()
    let first = AppVolumeService(backend: firstBackend, userDefaults: defaults)
    firstBackend.send(candidates: [.music])
    first.setVolume(0.63, for: "com.apple.Music")

    let secondBackend = FakeAppVolumeRoutingBackend()
    let second = AppVolumeService(backend: secondBackend, userDefaults: defaults)
    secondBackend.send(candidates: [.music])

    #expect(second.session(id: "com.apple.Music")?.volume == 0.63)
}

@Test("已记忆 App 会保留上次已知的应用图标路径")
@MainActor
func rememberedAppRetainsLastKnownBundleURL() throws {
    let defaults = try makeVolumeDefaults("rememberedAppIcon")
    let backend = FakeAppVolumeRoutingBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music])
    service.setVolume(0.63, for: "com.apple.Music")

    backend.send(candidates: [])

    #expect(
        service.session(id: "com.apple.Music")?.bundleURL
            == URL(fileURLWithPath: "/System/Applications/Music.app")
    )
}

@Test("成功创建路由后会记住授权状态")
@MainActor
func successfulRoutePersistsPermissionState() throws {
    let defaults = try makeVolumeDefaults("permissionPersistence")
    let firstBackend = FakeAppVolumeRoutingBackend()
    let first = AppVolumeService(backend: firstBackend, userDefaults: defaults)
    firstBackend.send(candidates: [.music])
    first.setEnabled(true)
    first.setVolume(0.63, for: "com.apple.Music")

    let second = AppVolumeService(
        backend: FakeAppVolumeRoutingBackend(),
        userDefaults: defaults
    )

    #expect(second.permissionState == .authorized)
}

@Test("是否存在已记忆音量会随调整和全部重置更新")
@MainActor
func appVolumeServiceReportsRememberedProfiles() throws {
    let defaults = try makeVolumeDefaults("hasProfiles")
    let backend = FakeAppVolumeRoutingBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music])

    #expect(!service.hasProfiles)
    service.setVolume(0.63, for: "com.apple.Music")
    #expect(service.hasProfiles)
    service.resetAllProfiles()
    #expect(!service.hasProfiles)
}

@Test("录音权限被拒绝时回滚 App 音量滑杆")
@MainActor
func permissionDenialRollsBackAppVolume() throws {
    let defaults = try makeVolumeDefaults("permissionRollback")
    let backend = FakeAppVolumeRoutingBackend()
    backend.applyError = .permissionDenied
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music])
    service.setEnabled(true)

    service.setVolume(0.37, for: "com.apple.Music")

    #expect(service.session(id: "com.apple.Music")?.volume == 1)
    #expect(service.permissionState == .denied)
    #expect(service.session(id: "com.apple.Music")?.errorMessage != nil)
}

@Test("非权限路由错误保留用户音量并允许恢复到百分百")
@MainActor
func nonPermissionFailureKeepsRequestedVolumeAndCanBypass() throws {
    let defaults = try makeVolumeDefaults("formatFailureRecovery")
    let backend = FakeAppVolumeRoutingBackend()
    backend.applyError = .unsupportedFormat
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music])
    service.setEnabled(true)

    service.setVolume(0.37, for: "com.apple.Music")
    #expect(service.session(id: "com.apple.Music")?.volume == 0.37)
    #expect(service.session(id: "com.apple.Music")?.errorMessage != nil)

    service.setVolume(1, for: "com.apple.Music")
    #expect(service.session(id: "com.apple.Music")?.volume == 1)
    #expect(service.session(id: "com.apple.Music")?.errorMessage == nil)
    #expect(service.errorMessage == nil)
    #expect(backend.removed.last == "com.apple.Music")
}

@Test("重置 Profile 会清除该 App 的路由错误")
@MainActor
func resettingProfileClearsRouteError() throws {
    let defaults = try makeVolumeDefaults("resetError")
    let backend = FakeAppVolumeRoutingBackend()
    backend.applyError = .unsupportedFormat
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music])
    service.setEnabled(true)
    service.setVolume(0.37, for: "com.apple.Music")

    service.resetProfile(for: "com.apple.Music")

    #expect(service.session(id: "com.apple.Music")?.volume == 1)
    #expect(service.session(id: "com.apple.Music")?.errorMessage == nil)
    #expect(service.errorMessage == nil)
}

@Test("瞬态无效缓冲达到阈值前不会终止路由")
func transientInvalidBuffersNeedConsecutiveFailures() {
    for count in 1..<AppVolumeRouteFailurePolicy.consecutiveFailureLimit {
        #expect(!AppVolumeRouteFailurePolicy.shouldAbort(consecutiveFailures: count))
    }
    #expect(AppVolumeRouteFailurePolicy.shouldAbort(
        consecutiveFailures: AppVolumeRouteFailurePolicy.consecutiveFailureLimit
    ))
}

@Test("音频进程退出时销毁该 App 路由")
@MainActor
func processExitRemovesAppRoute() throws {
    let defaults = try makeVolumeDefaults("processExit")
    let backend = FakeAppVolumeRoutingBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)
    backend.send(candidates: [.music])
    service.setEnabled(true)
    service.setVolume(0.42, for: "com.apple.Music")

    backend.send(candidates: [])

    #expect(backend.removed.last == "com.apple.Music")
}

@Test("麦克风电平采集仅在音量设置页明确请求时开启")
@MainActor
func inputLevelMonitoringRequiresExplicitRequest() throws {
    let defaults = try makeVolumeDefaults("inputLevelMonitoring")
    let backend = FakeAppVolumeRoutingBackend()
    let service = AppVolumeService(backend: backend, userDefaults: defaults)

    service.start()

    #expect(backend.inputLevelMonitorStartCount == 0)

    service.startInputLevelMonitoring()
    #expect(backend.inputLevelMonitorStartCount == 1)

    service.stopInputLevelMonitoring()
    #expect(backend.inputLevelMonitorStopCount == 1)
}

@MainActor
private final class FakeAppVolumeRoutingBackend: AppVolumeRoutingBackend {
    var onSnapshot: ((AppVolumeBackendSnapshot) -> Void)?
    var applied: [(id: String, volume: Double)] = []
    var removed: [String] = []
    var applyError: AppVolumeRoutingError?
    var inputLevelMonitorStartCount = 0
    var inputLevelMonitorStopCount = 0

    func start() {}
    func stop() {}
    func startInputLevelMonitoring() { inputLevelMonitorStartCount += 1 }
    func stopInputLevelMonitoring() { inputLevelMonitorStopCount += 1 }

    func apply(volume: Double, to target: AppVolumeTarget) throws {
        if let applyError { throw applyError }
        applied.append((target.rootBundleID, volume))
    }

    func removeRoute(for rootBundleID: String) {
        removed.append(rootBundleID)
    }

    func setMasterVolume(_ volume: Double) throws {}
    func setMasterMuted(_ muted: Bool) throws {}

    func send(candidates: [AppAudioProcessCandidate]) {
        onSnapshot?(
            AppVolumeBackendSnapshot(
                candidates: candidates,
                output: .fixture
            )
        )
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
}

private extension SystemOutputVolumeState {
    static let fixture = SystemOutputVolumeState(
        deviceID: 99,
        deviceName: "Mac 扬声器",
        volume: 0.5,
        isMuted: false,
        canSetVolume: true,
        canSetMute: true
    )
}

private func makeVolumeDefaults(_ name: String) throws -> UserDefaults {
    let suiteName = "AppVolumeServiceTests.\(name).\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@Test("左右平衡居中不衰减，全左或全右会静掉对侧")
func channelMixUsesBalanceLaw() {
    let center = AppVolumeChannelMix.panGains(pan: 0)
    #expect(center.left == 1)
    #expect(center.right == 1)

    let fullRight = AppVolumeChannelMix.panGains(pan: 1)
    #expect(fullRight.left == 0)
    #expect(fullRight.right == 1)

    let fullLeft = AppVolumeChannelMix.panGains(pan: -1)
    #expect(fullLeft.left == 1)
    #expect(fullLeft.right == 0)

    let halfRight = AppVolumeChannelMix.panGains(pan: 0.5)
    #expect(abs(halfRight.left - 0.5) < 0.0001)
    #expect(halfRight.right == 1)

    // 越界与非有限值都会被夹到有效范围
    #expect(AppVolumeChannelMix.normalizedPan(3) == 1)
    #expect(AppVolumeChannelMix.normalizedPan(-3) == -1)
    #expect(AppVolumeChannelMix.normalizedPan(.nan) == 0)
}

@Test("单声道下混对多声道取平均，单声道原样返回")
func channelMixDownmixesToMono() {
    #expect(AppVolumeChannelMix.monoSample(1.0, channelCount: 2) == 0.5)
    #expect(AppVolumeChannelMix.monoSample(0.6, channelCount: 3) == 0.2)
    #expect(AppVolumeChannelMix.monoSample(0.4, channelCount: 1) == 0.4)
}

@Test("菜单栏音量标题按模式给出主音量或最响 App，并夹住百分比")
func menuBarVolumeTitlesFollowMode() {
    #expect(AppVolumeMenuBarPresenter.title(mode: .off, masterVolume: 0.42, isMuted: false, loudest: nil) == nil)
    // 百分比固定三位宽，避免调音量时标题宽度变化
    #expect(AppVolumeMenuBarPresenter.title(mode: .master, masterVolume: 0.42, isMuted: false, loudest: nil) == "🔊  42%")
    #expect(
        AppVolumeMenuBarPresenter.title(mode: .loudest, masterVolume: 0.1, isMuted: false, loudest: ("音乐", 0.8))
            == "🔊 音乐  80%"
    )
    // 没有正在发声的 App 时退回主音量
    #expect(AppVolumeMenuBarPresenter.title(mode: .loudest, masterVolume: 0.5, isMuted: false, loudest: nil) == "🔊  50%")
    #expect(AppVolumeMenuBarPresenter.percent(2) == "100%")
    #expect(AppVolumeMenuBarPresenter.percent(-1) == "  0%")
    #expect(AppVolumeMenuBarPresenter.percent(0.05) == "  5%")
}

@Test("菜单栏音量标题宽度稳定：位数、静音与长名字都不会改变宽度")
func menuBarVolumeTitleWidthIsStable() {
    // 同一模式下不同音量长度一致（弹窗锚在状态项上，宽度变化会带着弹窗抖）
    let lengths = [0.0, 0.05, 0.42, 0.999, 1.0].map {
        AppVolumeMenuBarPresenter.title(mode: .master, masterVolume: $0, isMuted: false, loudest: nil)?.count
    }
    #expect(Set(lengths.compactMap { $0 }).count == 1)

    // 静音与正常状态等宽
    let muted = AppVolumeMenuBarPresenter.title(mode: .master, masterVolume: 0.5, isMuted: true, loudest: nil)
    let normal = AppVolumeMenuBarPresenter.title(mode: .master, masterVolume: 0.5, isMuted: false, loudest: nil)
    #expect(muted?.count == normal?.count)

    // 最响 App：同一 App 调音量长度不变
    let quiet = AppVolumeMenuBarPresenter.title(mode: .loudest, masterVolume: 0.1, isMuted: false, loudest: ("Chrome", 0.09))
    let loud = AppVolumeMenuBarPresenter.title(mode: .loudest, masterVolume: 0.1, isMuted: false, loudest: ("Chrome", 1.0))
    #expect(quiet?.count == loud?.count)

    // 超长 App 名会被截断，宽度有上界
    let longName = String(repeating: "超长名字", count: 6)
    let truncated = try? #require(
        AppVolumeMenuBarPresenter.title(mode: .loudest, masterVolume: 0.5, isMuted: false, loudest: (longName, 0.8))
    )
    #expect(truncated?.contains("…") == true)

    // 长名字与截断后的上限一致，不会无限变宽
    let bounded = "🔊 ".count + AppVolumeMenuBarPresenter.maximumAppNameLength + 1 + 4
    #expect((truncated?.count ?? 0) <= bounded)
}
