import AppKit
import Carbon
import CoreBluetooth
import CoreGraphics
import Foundation
import Observation
import UserNotifications

/// 系统权限的可读状态。自动化没有公开的预检 API，因此单独标为需要验证，避免伪造“已授权”。
enum RuntimePermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    case requiresVerification

    var isGranted: Bool { self == .granted }

    var titleKey: String {
        switch self {
        case .granted: "runtime.permission.granted"
        case .denied: "runtime.permission.denied"
        case .notDetermined: "runtime.permission.notDetermined"
        case .requiresVerification: "runtime.permission.requiresVerification"
        }
    }

    var symbolName: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.octagon.fill"
        case .notDetermined, .requiresVerification: "exclamationmark.triangle.fill"
        }
    }
}

/// 统一描述一个插件此刻是否可供使用，而不把“已启用”误当成“实际可用”。
enum PluginReadiness: Equatable, Sendable {
    case disabled
    case running
    case stopped
    case failed(String)
    case requiresPermissions([BuiltInPluginPermission])

    var isAttentionRequired: Bool {
        switch self {
        case .failed, .requiresPermissions: true
        case .disabled, .running, .stopped: false
        }
    }

    var titleKey: String {
        switch self {
        case .disabled: "runtime.plugin.disabled"
        case .running: "runtime.plugin.running"
        case .stopped: "runtime.plugin.stopped"
        case .failed: "runtime.plugin.failed"
        case .requiresPermissions: "runtime.plugin.requiresPermissions"
        }
    }

    var symbolName: String {
        switch self {
        case .disabled: "pause.circle.fill"
        case .running: "checkmark.circle.fill"
        case .stopped: "minus.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .requiresPermissions: "exclamationmark.triangle.fill"
        }
    }
}

struct RuntimeStatusSummary: Equatable, Sendable {
    var running: Int = 0
    var attention: Int = 0
    var disabled: Int = 0
    var stopped: Int = 0
}

/// 用系统公开的 Apple Event 预检 API 读取 MenuTools 对 System Events 的自动化授权。
/// 预检不会发送事件，也不会弹出授权对话框；System Events 未运行时先在后台启动它。
enum AutomationPermissionPreflight {
    private static let systemEventsBundleIdentifier = "com.apple.systemevents"

    static func status(forPreflightStatus status: OSStatus) -> RuntimePermissionStatus {
        switch status {
        case noErr: .granted
        case OSStatus(errAEEventNotPermitted): .denied
        case OSStatus(errAEEventWouldRequireUserConsent): .notDetermined
        default: .requiresVerification
        }
    }

    @MainActor
    static func systemEventsStatus() async -> RuntimePermissionStatus {
        guard await ensureSystemEventsIsRunning() else { return .requiresVerification }
        return await Task.detached(priority: .utility) {
            let descriptor = NSAppleEventDescriptor(
                bundleIdentifier: systemEventsBundleIdentifier
            )
            guard let target = descriptor.aeDesc else {
                return RuntimePermissionStatus.requiresVerification
            }
            let result = AEDeterminePermissionToAutomateTarget(
                target,
                AEEventClass(typeWildCard),
                AEEventID(typeWildCard),
                false
            )
            return status(forPreflightStatus: result)
        }.value
    }

    @MainActor
    private static func ensureSystemEventsIsRunning() async -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == systemEventsBundleIdentifier
        }) {
            return true
        }
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: systemEventsBundleIdentifier
        ) else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                continuation.resume(returning: application != nil && error == nil)
            }
        }
    }
}

/// 纯状态归类逻辑：测试不需要触碰 TCC 或 AppKit，也保证“失败原因优先于权限提示”。
enum RuntimeStatusCenter {
    static func readiness(
        for manifest: BuiltInPluginManifest,
        isEnabled: Bool,
        runtimeState: BuiltInPluginRuntimeState,
        permissions: [BuiltInPluginPermission: RuntimePermissionStatus]
    ) -> PluginReadiness {
        guard isEnabled else { return .disabled }
        if case let .failed(message) = runtimeState { return .failed(message) }

        let missing = manifest.requiredPermissions
            .filter { permissions[$0, default: .notDetermined].isGranted == false }
            .sorted { $0.rawValue < $1.rawValue }
        guard missing.isEmpty else { return .requiresPermissions(missing) }

        return switch runtimeState {
        case .running: .running
        case .stopped: .stopped
        case .failed(let message): .failed(message)
        }
    }

    static func summary(for readiness: [PluginReadiness]) -> RuntimeStatusSummary {
        readiness.reduce(into: RuntimeStatusSummary()) { result, item in
            switch item {
            case .running: result.running += 1
            case .failed, .requiresPermissions: result.attention += 1
            case .disabled: result.disabled += 1
            case .stopped: result.stopped += 1
            }
        }
    }
}

/// 实际权限读取集中在这里。读取不会触发 TCC 授权弹窗；用户只能主动点击设置跳转后再刷新。
@MainActor
@Observable
final class RuntimePermissionMonitor {
    static let shared = RuntimePermissionMonitor()

    private(set) var states: [BuiltInPluginPermission: RuntimePermissionStatus]
    private(set) var isRefreshing = false

    private init() {
        states = Dictionary(uniqueKeysWithValues: BuiltInPluginPermission.allCases.map {
            ($0, .notDetermined)
        })
    }

    func refresh() {
        isRefreshing = true
        states[.accessibility] = AXIsProcessTrusted() ? .granted : .denied
        states[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .denied
        states[.bluetooth] = bluetoothStatus()
        states[.systemAudioRecording] = appVolumePermissionStatus()

        Task { [weak self] in
            let notification = await Self.notificationStatus()
            let automation = await AutomationPermissionPreflight.systemEventsStatus()
            guard let self else { return }
            states[.notifications] = notification
            states[.automation] = automation
            isRefreshing = false
        }
    }

    private func bluetoothStatus() -> RuntimePermissionStatus {
        switch CBManager.authorization {
        case .allowedAlways: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    private func appVolumePermissionStatus() -> RuntimePermissionStatus {
        switch AppVolumeService.shared.permissionState {
        case .authorized: .granted
        case .denied: .denied
        case .notRequested: .notDetermined
        }
    }

    private static func notificationStatus() async -> RuntimePermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}

enum RuntimePermissionSettingsLink {
    static func url(for permission: BuiltInPluginPermission) -> URL? {
        switch permission {
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .automation:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .bluetooth:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        case .notifications:
            URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        case .screenRecording, .systemAudioRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }
}
