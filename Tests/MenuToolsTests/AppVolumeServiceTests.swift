import Foundation
import Testing
@testable import MenuTools

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

@Test("DSP 在一个缓冲区内平滑变化到目标增益")
func appVolumeDSPAppliesSmoothRamp() {
    var samples: [Float] = [1, 1, 1, 1]

    let finalGain = AppVolumeDSP.applyGain(to: &samples, from: 1, to: 0)

    #expect(samples == [0.75, 0.5, 0.25, 0])
    #expect(finalGain == 0)
}

@Test("DSP 支持任意增益、静音并限制输出范围")
func appVolumeDSPSupportsArbitraryGainMuteAndClipping() {
    var attenuated: [Float] = [1, -1]
    _ = AppVolumeDSP.applyGain(to: &attenuated, from: 0.37, to: 0.37)
    #expect(attenuated == [0.37, -0.37])

    var muted: [Float] = [0.8, -0.8]
    _ = AppVolumeDSP.applyGain(to: &muted, from: 0, to: 0)
    #expect(muted == [0, 0])

    var clipped: [Float] = [2, -2]
    _ = AppVolumeDSP.applyGain(to: &clipped, from: 1, to: 1)
    #expect(clipped == [1, -1])
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

@MainActor
private final class FakeAppVolumeRoutingBackend: AppVolumeRoutingBackend {
    var onSnapshot: ((AppVolumeBackendSnapshot) -> Void)?
    var applied: [(id: String, volume: Double)] = []
    var removed: [String] = []
    var applyError: AppVolumeRoutingError?

    func start() {}
    func stop() {}

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
