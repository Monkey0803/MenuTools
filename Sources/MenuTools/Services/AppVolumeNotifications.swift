import Foundation
import UserNotifications

/// 音量模块的通知授权状态。
enum AppVolumeNotificationPermission: String, CaseIterable, Equatable, Sendable {
    case notRequested
    case authorized
    case denied

    var titleKey: String {
        switch self {
        case .notRequested: return "volume.notification.permission.notRequested"
        case .authorized: return "volume.notification.permission.authorized"
        case .denied: return "volume.notification.permission.denied"
        }
    }

    /// 系统授权状态到界面状态的映射；纯函数，便于回归。
    static func resolve(_ status: UNAuthorizationStatus) -> Self {
        switch status {
        case .notDetermined: return .notRequested
        case .denied: return .denied
        case .authorized, .provisional: return .authorized
        @unknown default: return .notRequested
        }
    }
}

/// 音量模块会推送的事件类型。
enum AppVolumeNotificationKind: String, CaseIterable, Sendable {
    case clipping
    case automation
    case hearingProtection

    var titleKey: String { "volume.notification.\(rawValue)" }
    var detailKey: String { "volume.notification.\(rawValue).desc" }
}

/// 一条待推送的音量事件。
enum AppVolumeNotificationEvent: Equatable, Sendable {
    /// App 输出已经削波（只对已建立路由、能拿到电平的 App 生效）。
    case clipping(appName: String, appID: String)
    /// 自动化规则套用了预设。
    case automation(presetName: String)
    /// 长时间高音量，触发听力保护提示。
    case hearingProtection(deviceName: String)

    var kind: AppVolumeNotificationKind {
        switch self {
        case .clipping: return .clipping
        case .automation: return .automation
        case .hearingProtection: return .hearingProtection
        }
    }

    /// 去重键：削波按 App 区分，其余按类型区分。
    var deduplicationKey: String {
        switch self {
        case let .clipping(_, appID): return "clipping:\(appID)"
        case .automation: return "automation"
        case .hearingProtection: return "hearingProtection"
        }
    }
}

/// 开关与冷却时间：决定某一类事件当前能不能推送。
struct AppVolumeNotificationPolicy: Equatable, Sendable {
    /// 削波提醒：同一 App 10 分钟内只提醒一次。
    static let clippingCooldown: TimeInterval = 600
    /// 自动化提醒：30 秒内只提醒一次，避免切换设备时刷屏。
    static let automationCooldown: TimeInterval = 30
    /// 听力保护：同一轮 1 小时内只提醒一次。
    static let hearingCooldown: TimeInterval = 3_600

    var clippingEnabled = true
    var automationEnabled = false
    var hearingEnabled = true

    func isEnabled(_ kind: AppVolumeNotificationKind) -> Bool {
        switch kind {
        case .clipping: return clippingEnabled
        case .automation: return automationEnabled
        case .hearingProtection: return hearingEnabled
        }
    }

    func cooldown(for kind: AppVolumeNotificationKind) -> TimeInterval {
        switch kind {
        case .clipping: return Self.clippingCooldown
        case .automation: return Self.automationCooldown
        case .hearingProtection: return Self.hearingCooldown
        }
    }
}

/// 记录每类事件上次推送时间，用于冷却与去重。
struct AppVolumeNotificationTracker: Equatable, Sendable {
    private var lastSentAt: [String: Date] = [:]

    /// 判断是否应该推送；返回 true 时同时记下本次时间。
    mutating func shouldSend(
        _ event: AppVolumeNotificationEvent,
        policy: AppVolumeNotificationPolicy,
        now: Date
    ) -> Bool {
        guard policy.isEnabled(event.kind) else { return false }
        let key = event.deduplicationKey
        if let last = lastSentAt[key], now.timeIntervalSince(last) < policy.cooldown(for: event.kind) {
            return false
        }
        lastSentAt[key] = now
        return true
    }

    mutating func reset() {
        lastSentAt.removeAll()
    }
}

@MainActor
protocol AppVolumeAlerting {
    func requestPermission()
    func currentPermission() async -> AppVolumeNotificationPermission
    func send(_ event: AppVolumeNotificationEvent)
}

@MainActor
final class UserNotificationAppVolumeAlerter: AppVolumeAlerting {
    /// 惰性获取：测试进程里 `UNUserNotificationCenter.current()` 会直接抛异常，
    /// 只有真正要发通知或读授权时才触碰它。
    private var center: UNUserNotificationCenter {
        UNUserNotificationCenter.current()
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func currentPermission() async -> AppVolumeNotificationPermission {
        // 只在回调内部取 Sendable 的授权状态，避免跨 actor 传递 UNNotificationSettings。
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(
                    returning: AppVolumeNotificationPermission.resolve(settings.authorizationStatus)
                )
            }
        }
    }

    func send(_ event: AppVolumeNotificationEvent) {
        let content = UNMutableNotificationContent()
        content.sound = .default
        switch event {
        case let .clipping(appName, _):
            content.title = L("volume.notification.clipping.title", appName)
            content.body = L("volume.notification.clipping.body")
        case let .automation(presetName):
            content.title = L("volume.notification.automation.title", presetName)
            content.body = L("volume.notification.automation.body")
        case let .hearingProtection(deviceName):
            content.title = L("volume.notification.hearingProtection.title", deviceName)
            content.body = L("volume.notification.hearingProtection.body")
        }
        let request = UNNotificationRequest(
            identifier: "app-volume-\(event.deduplicationKey)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
