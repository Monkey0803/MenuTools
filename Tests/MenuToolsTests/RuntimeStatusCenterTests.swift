import Testing
@testable import MenuTools

@Test("未授权的所需权限会让已启用模块进入待处理状态")
func pluginReadinessRequiresMissingPermissions() {
    let manifest = BuiltInPluginManifest(
        id: .screenshot,
        category: .productivity,
        titleKey: "plugin.screenshot.title",
        descriptionKey: "plugin.screenshot.description",
        symbol: "camera.viewfinder",
        requiredPermissions: [.accessibility, .screenRecording],
        dependencies: [],
        defaultEnabled: true
    )

    let readiness = RuntimeStatusCenter.readiness(
        for: manifest,
        isEnabled: true,
        runtimeState: .running,
        permissions: [
            .accessibility: .granted,
            .screenRecording: .denied
        ]
    )

    #expect(readiness == .requiresPermissions([.screenRecording]))
}

@Test("启动失败优先显示运行错误而不是权限提示")
func pluginReadinessShowsRuntimeFailureFirst() {
    let manifest = BuiltInPluginManifest(
        id: .appVolume,
        category: .media,
        titleKey: "plugin.app-volume.title",
        descriptionKey: "plugin.app-volume.description",
        symbol: "speaker.wave.2.bubble",
        requiredPermissions: [.systemAudioRecording],
        dependencies: [],
        defaultEnabled: true
    )

    let readiness = RuntimeStatusCenter.readiness(
        for: manifest,
        isEnabled: true,
        runtimeState: .failed("route unavailable"),
        permissions: [.systemAudioRecording: .denied]
    )

    #expect(readiness == .failed("route unavailable"))
}

@Test("已停用模块不会被未授权权限误标为故障")
func disabledPluginReadinessStaysDisabled() {
    let manifest = BuiltInPluginManifest(
        id: .translation,
        category: .productivity,
        titleKey: "plugin.translation.title",
        descriptionKey: "plugin.translation.description",
        symbol: "character.bubble",
        requiredPermissions: [.accessibility],
        dependencies: [],
        defaultEnabled: true
    )

    let readiness = RuntimeStatusCenter.readiness(
        for: manifest,
        isEnabled: false,
        runtimeState: .stopped,
        permissions: [.accessibility: .denied]
    )

    #expect(readiness == .disabled)
}

@Test("运行概览分别统计正常、待处理与停用模块")
func runtimeSummaryCountsReadiness() {
    let summary = RuntimeStatusCenter.summary(for: [
        .running,
        .requiresPermissions([.accessibility]),
        .failed("failed"),
        .disabled,
        .stopped
    ])

    #expect(summary.running == 1)
    #expect(summary.attention == 2)
    #expect(summary.disabled == 1)
    #expect(summary.stopped == 1)
}

@Test("自动化预检会区分已授权、拒绝和待授权")
func automationPermissionPreflightMapsSystemStatuses() {
    #expect(AutomationPermissionPreflight.status(forPreflightStatus: 0) == .granted)
    #expect(AutomationPermissionPreflight.status(forPreflightStatus: -1743) == .denied)
    #expect(AutomationPermissionPreflight.status(forPreflightStatus: -1744) == .notDetermined)
}
