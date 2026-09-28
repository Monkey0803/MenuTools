import Foundation
import Testing
@testable import MenuTools

@Test("电池健康解析支持嵌套 system_profiler 数据")
func batteryHealthParserReadsNestedData() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "SPPowerDataType": [[
            "_name": "sppower_battery_health_info",
            "Battery Information": [
                "Condition": "Normal",
                "Cycle Count": 42,
                "Maximum Capacity": 96,
                "State of Charge (%)": 83,
                "Charging": "Yes"
            ]
        ]]
    ])

    let snapshot = try #require(BatteryHealthParser.parse(data: data))
    #expect(snapshot.condition == "Normal")
    #expect(snapshot.cycleCount == 42)
    #expect(snapshot.healthPercent == 96)
    #expect(snapshot.currentPercent == 83)
    #expect(snapshot.isCharging)
}

@Test("无电池数据时静默返回 nil")
func batteryHealthParserReturnsNilWithoutBattery() throws {
    let data = try JSONSerialization.data(withJSONObject: ["SPPowerDataType": []])
    #expect(BatteryHealthParser.parse(data: data) == nil)
}

@Test("电池健康告警判定：健康不告警、健康度低或条件异常才告警")
func batteryHealthAlertPolicyDecidesHealth() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let healthy = BatteryHealthSnapshot(
        condition: "Normal", healthPercent: 96, cycleCount: 42, currentPercent: 80, isCharging: false
    )
    var policy = BatteryHealthAlertPolicy()

    // evaluate 是 mutating：不能在 #expect 表达式里直接调用
    let healthyResult = policy.evaluate(snapshot: healthy, now: base)
    #expect(!healthyResult)
    #expect(policy.lastFiredAt == nil)

    // 健康度低于 80%：苹果的「建议维修」线
    let degraded = BatteryHealthSnapshot(
        condition: "Normal", healthPercent: 72, cycleCount: 600, currentPercent: 50, isCharging: false
    )
    let degradedResult = policy.evaluate(snapshot: degraded, now: base)
    #expect(degradedResult)
    #expect(policy.lastFiredAt == base)

    // 冷却期内不重复（电池健康变化很慢，冷却取 7 天）
    let withinCooldown = policy.evaluate(snapshot: degraded, now: base.addingTimeInterval(6 * 86_400))
    #expect(!withinCooldown)
    let afterCooldown = policy.evaluate(snapshot: degraded, now: base.addingTimeInterval(8 * 86_400))
    #expect(afterCooldown)

    // 条件本身异常（Service Battery / 建议维修）也要告警，即使健康度读数缺失
    var conditionPolicy = BatteryHealthAlertPolicy()
    let serviceNeeded = BatteryHealthSnapshot(
        condition: "Service Battery", healthPercent: nil, cycleCount: 900, currentPercent: 40, isCharging: false
    )
    let conditionResult = conditionPolicy.evaluate(snapshot: serviceNeeded, now: base)
    #expect(conditionResult)

    // 没有电池（桌面 Mac）：静默降级，不告警也不报错
    var desktopPolicy = BatteryHealthAlertPolicy()
    let desktop = BatteryHealthSnapshot(
        condition: nil, healthPercent: nil, cycleCount: nil, currentPercent: nil, isCharging: false
    )
    let desktopResult = desktopPolicy.evaluate(snapshot: desktop, now: base)
    #expect(!desktopResult)
    let nilResult = desktopPolicy.evaluate(snapshot: nil, now: base)
    #expect(!nilResult)
    #expect(desktopPolicy.lastFiredAt == nil)
}

private struct StubBatteryHealthProvider: BatteryHealthProviding {
    let snapshot: BatteryHealthSnapshot?
    func read() -> BatteryHealthSnapshot? { snapshot }
}

private final class RecordingBatteryAlerter: SystemResourceAlerting, @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [SystemResourceAlertKind] = []
    var sent: [SystemResourceAlertKind] { lock.withLock { kinds } }

    func requestPermission() {}
    func currentPermission() async -> SystemResourceNotificationPermission { .authorized }
    func send(_ kind: SystemResourceAlertKind, snapshot: SystemResourceSnapshot?) {
        lock.withLock { kinds.append(kind) }
    }
}

@Test("服务在电池健康偏低时告警，冷却存偏好，无电池时静默")
@MainActor
func batteryServiceAlertsOnDegradedHealth() async throws {
    let suiteName = "BatteryAlert.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: SystemResourceAlertSettings.enabledKey)

    let degraded = BatteryHealthSnapshot(
        condition: "Normal", healthPercent: 70, cycleCount: 800, currentPercent: 40, isCharging: false
    )
    let alerter = RecordingBatteryAlerter()
    let service = BatteryHealthService(
        provider: StubBatteryHealthProvider(snapshot: degraded),
        alerter: alerter,
        userDefaults: defaults
    )

    service.refresh()
    for _ in 0 ..< 200 where service.snapshot == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    for _ in 0 ..< 200 where alerter.sent.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(alerter.sent == [.batteryHealth])
    // 冷却写进偏好：重启后不会重复提醒
    #expect(BatteryHealthAlertCooldown.load(from: defaults) != nil)

    // 再刷一次仍在冷却内 → 不再告警
    service.refresh()
    try await Task.sleep(for: .milliseconds(60))
    #expect(alerter.sent == [.batteryHealth])

    // 关掉「资源告警」总开关后不再告警
    defaults.set(false, forKey: SystemResourceAlertSettings.enabledKey)
    let secondAlerter = RecordingBatteryAlerter()
    let disabledService = BatteryHealthService(
        provider: StubBatteryHealthProvider(snapshot: degraded),
        alerter: secondAlerter,
        userDefaults: defaults
    )
    disabledService.refresh()
    try await Task.sleep(for: .milliseconds(80))
    #expect(secondAlerter.sent.isEmpty)

    // 无电池（桌面 Mac）：静默，不告警也不写冷却
    let desktopSuite = "BatteryAlertDesktop.\(UUID().uuidString)"
    let desktopDefaults = try #require(UserDefaults(suiteName: desktopSuite))
    desktopDefaults.removePersistentDomain(forName: desktopSuite)
    desktopDefaults.set(true, forKey: SystemResourceAlertSettings.enabledKey)
    let desktopAlerter = RecordingBatteryAlerter()
    let desktopService = BatteryHealthService(
        provider: StubBatteryHealthProvider(snapshot: nil),
        alerter: desktopAlerter,
        userDefaults: desktopDefaults
    )
    desktopService.refresh()
    try await Task.sleep(for: .milliseconds(80))
    #expect(desktopAlerter.sent.isEmpty)
    #expect(BatteryHealthAlertCooldown.load(from: desktopDefaults) == nil)
}
