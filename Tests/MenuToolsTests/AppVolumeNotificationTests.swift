import Foundation
import Testing
import UserNotifications
@testable import MenuTools

@Test("通知策略按类型开关与冷却时间抑制重复事件")
func notificationTrackerRespectsPolicyAndCooldown() {
    var tracker = AppVolumeNotificationTracker()
    let policy = AppVolumeNotificationPolicy(
        clippingEnabled: true,
        automationEnabled: false,
        hearingEnabled: true
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    // 关闭的类型不推送
    let disabledKind = tracker.shouldSend(.automation(presetName: "夜间"), policy: policy, now: now)
    #expect(!disabledKind)

    // 削波按 App 区分，同一 App 10 分钟内只推一次
    let firstClipping = tracker.shouldSend(.clipping(appName: "音乐", appID: "music"), policy: policy, now: now)
    #expect(firstClipping)
    let repeatedWithinCooldown = tracker.shouldSend(
        .clipping(appName: "音乐", appID: "music"),
        policy: policy,
        now: now.addingTimeInterval(60)
    )
    #expect(!repeatedWithinCooldown)
    let otherApp = tracker.shouldSend(.clipping(appName: "播客", appID: "podcasts"), policy: policy, now: now)
    #expect(otherApp)
    let afterCooldown = tracker.shouldSend(
        .clipping(appName: "音乐", appID: "music"),
        policy: policy,
        now: now.addingTimeInterval(601)
    )
    #expect(afterCooldown)

    // 听力保护 1 小时冷却
    let firstHearing = tracker.shouldSend(.hearingProtection(deviceName: "AirPods"), policy: policy, now: now)
    #expect(firstHearing)
    let hearingWithinCooldown = tracker.shouldSend(
        .hearingProtection(deviceName: "AirPods"),
        policy: policy,
        now: now.addingTimeInterval(1_800)
    )
    #expect(!hearingWithinCooldown)
    let hearingAfterCooldown = tracker.shouldSend(
        .hearingProtection(deviceName: "AirPods"),
        policy: policy,
        now: now.addingTimeInterval(3_601)
    )
    #expect(hearingAfterCooldown)
}

@Test("打开自动化提醒后同一冷却期内只推一次")
func notificationTrackerAutomationCooldown() {
    var tracker = AppVolumeNotificationTracker()
    let policy = AppVolumeNotificationPolicy(
        clippingEnabled: false,
        automationEnabled: true,
        hearingEnabled: false
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let first = tracker.shouldSend(.automation(presetName: "通勤"), policy: policy, now: now)
    #expect(first)
    let withinCooldown = tracker.shouldSend(
        .automation(presetName: "通勤"),
        policy: policy,
        now: now.addingTimeInterval(10)
    )
    #expect(!withinCooldown)
    let afterCooldown = tracker.shouldSend(
        .automation(presetName: "通勤"),
        policy: policy,
        now: now.addingTimeInterval(31)
    )
    #expect(afterCooldown)
}

@Test("通知授权状态映射覆盖未决定、拒绝与已授权")
func notificationPermissionMapsSystemStatus() {
    #expect(AppVolumeNotificationPermission.resolve(.notDetermined) == .notRequested)
    #expect(AppVolumeNotificationPermission.resolve(.denied) == .denied)
    #expect(AppVolumeNotificationPermission.resolve(.authorized) == .authorized)
    #expect(AppVolumeNotificationPermission.resolve(.provisional) == .authorized)
}

@Test("事件类型与去重键稳定")
func notificationEventKindsAndKeys() {
    #expect(AppVolumeNotificationKind.allCases == [.clipping, .automation, .hearingProtection])
    #expect(AppVolumeNotificationEvent.clipping(appName: "音乐", appID: "music").kind == .clipping)
    #expect(AppVolumeNotificationEvent.clipping(appName: "音乐", appID: "music").deduplicationKey == "clipping:music")
    #expect(AppVolumeNotificationEvent.automation(presetName: "夜间").deduplicationKey == "automation")
    #expect(AppVolumeNotificationEvent.hearingProtection(deviceName: "AirPods").deduplicationKey == "hearingProtection")
    // 每种类型都要有界面文案键
    for kind in AppVolumeNotificationKind.allCases {
        #expect(!kind.titleKey.isEmpty)
        #expect(!kind.detailKey.isEmpty)
    }
}