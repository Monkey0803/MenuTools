import Foundation
import UserNotifications

/// 资源告警类别。
enum SystemResourceAlertKind: String, CaseIterable, Equatable, Sendable {
    /// CPU 持续高于阈值。
    case cpuSustained
    /// 内存压力到临界。
    case memoryPressure
    /// 磁盘剩余不足。
    case diskSpace

    var titleKey: String { "resource.alert.\(rawValue)" }
    var detailKey: String { "resource.alert.\(rawValue).desc" }

    /// 同一类告警的冷却时间：避免持续高负载时刷屏。
    var cooldown: TimeInterval {
        switch self {
        case .cpuSustained: return 30 * 60
        case .memoryPressure: return 30 * 60
        case .diskSpace: return 24 * 60 * 60
        }
    }
}

/// 告警阈值配置。
struct SystemResourceAlertThresholds: Equatable, Sendable {
    var cpuUsage: Double = 0.9
    /// CPU 需要连续高于阈值多久才告警。
    var cpuSustainDuration: TimeInterval = 5 * 60
    /// 磁盘剩余比例低于该值时告警。
    var diskFreeRatio: Double = 0.1

    func normalized() -> Self {
        var copy = self
        copy.cpuUsage = min(max(copy.cpuUsage.isFinite ? copy.cpuUsage : 0.9, 0.1), 1)
        copy.cpuSustainDuration = min(max(copy.cpuSustainDuration, 30), 60 * 60)
        copy.diskFreeRatio = min(max(copy.diskFreeRatio.isFinite ? copy.diskFreeRatio : 0.1, 0.01), 0.9)
        return copy
    }
}

/// 资源告警判定：纯状态机，时间由调用方注入，便于回归。
///
/// - CPU 需要「持续高于阈值」达设定时长才告警，掉回阈值以下会重置计时；
/// - 内存只在临界时告警；
/// - 磁盘按剩余比例判定；
/// - 每类告警各自有冷却时间。
struct SystemResourceAlertPolicy: Equatable, Sendable {
    private(set) var cpuHighSince: Date?
    private(set) var lastFiredAt: [SystemResourceAlertKind: Date] = [:]

    mutating func reset() {
        cpuHighSince = nil
        lastFiredAt.removeAll()
    }

    mutating func evaluate(
        snapshot: SystemResourceSnapshot,
        now: Date,
        thresholds requestedThresholds: SystemResourceAlertThresholds
    ) -> [SystemResourceAlertKind] {
        let thresholds = requestedThresholds.normalized()
        var fired: [SystemResourceAlertKind] = []

        // CPU 持续高位
        if snapshot.cpuUsage >= thresholds.cpuUsage {
            if cpuHighSince == nil { cpuHighSince = now }
        } else {
            cpuHighSince = nil
        }
        if let since = cpuHighSince, now.timeIntervalSince(since) >= thresholds.cpuSustainDuration,
           shouldFire(.cpuSustained, now: now) {
            lastFiredAt[.cpuSustained] = now
            fired.append(.cpuSustained)
        }

        if snapshot.memoryPressure == .critical, shouldFire(.memoryPressure, now: now) {
            lastFiredAt[.memoryPressure] = now
            fired.append(.memoryPressure)
        }

        let freeRatio = snapshot.diskTotalBytes > 0
            ? Double(max(snapshot.diskAvailableBytes, 0)) / Double(snapshot.diskTotalBytes)
            : 1
        if freeRatio < thresholds.diskFreeRatio, shouldFire(.diskSpace, now: now) {
            lastFiredAt[.diskSpace] = now
            fired.append(.diskSpace)
        }

        return fired
    }

    func lastFired(_ kind: SystemResourceAlertKind) -> Date? {
        lastFiredAt[kind]
    }

    private func shouldFire(_ kind: SystemResourceAlertKind, now: Date) -> Bool {
        guard let last = lastFiredAt[kind] else { return true }
        return now.timeIntervalSince(last) >= kind.cooldown
    }
}

/// 资源告警的通知授权状态。
enum SystemResourceNotificationPermission: String, CaseIterable, Equatable, Sendable {
    case notRequested
    case authorized
    case denied

    var titleKey: String {
        switch self {
        case .notRequested: return "resource.alert.permission.notRequested"
        case .authorized: return "resource.alert.permission.authorized"
        case .denied: return "resource.alert.permission.denied"
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

@MainActor
protocol SystemResourceAlerting {
    func requestPermission()
    func currentPermission() async -> SystemResourceNotificationPermission
    func send(_ kind: SystemResourceAlertKind, snapshot: SystemResourceSnapshot)
}

@MainActor
final class UserNotificationSystemResourceAlerter: SystemResourceAlerting {
    /// 只有运行在 .app 里才真正触碰通知中心：测试进程（swiftpm-testing-helper）
    /// 没有 bundle proxy，`UNUserNotificationCenter.current()` 会直接抛异常。
    private var canPostNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private var center: UNUserNotificationCenter {
        UNUserNotificationCenter.current()
    }

    func requestPermission() {
        guard canPostNotifications else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func currentPermission() async -> SystemResourceNotificationPermission {
        guard canPostNotifications else { return .notRequested }
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(
                    returning: SystemResourceNotificationPermission.resolve(settings.authorizationStatus)
                )
            }
        }
    }

    func send(_ kind: SystemResourceAlertKind, snapshot: SystemResourceSnapshot) {
        guard canPostNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = L(kind.titleKey)
        content.body = L(kind.detailKey)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "system-resource-\(kind.rawValue)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
