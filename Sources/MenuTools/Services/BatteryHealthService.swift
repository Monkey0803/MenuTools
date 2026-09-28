import Foundation
import Observation

struct BatteryHealthSnapshot: Equatable, Sendable {
    let condition: String?
    let healthPercent: Int?
    let cycleCount: Int?
    let currentPercent: Int?
    let isCharging: Bool
}

/// 电池健康告警判定（纯逻辑，便于回归）。
///
/// 文档指出告警面原本只覆盖 CPU / 内存 / 磁盘，电池健康虽然早已读到
/// `condition` / `healthPercent` / `cycleCount`，却没有告警出口。
/// 判定只依赖这些已有读数，**无电池的桌面 Mac 静默降级**（快照为空或读数缺失一律不告警）。
struct BatteryHealthAlertPolicy: Equatable, Sendable {
    /// 健康度低于该值时告警：与苹果「建议维修」的经验阈值一致。
    static let healthPercentThreshold = 80
    /// 同一告警的冷却：电池健康变化很慢，重复提醒没有意义。
    static let cooldown: TimeInterval = 7 * 86_400

    private(set) var lastFiredAt: Date?

    mutating func restoreLastFiredAt(_ date: Date?) {
        lastFiredAt = date
    }

    /// 条件文本里出现这些词说明系统已经在提示维修。
    ///
    /// 只用 ASCII 标记：`system_profiler` 的这一项输出为英文（Normal / Service Battery），
    /// 而本仓库禁止在源码里硬编码中文（有 L10n 用例守护）。
    /// 主判据是**数值**健康度（与语言无关），这里只是第二道网。
    private static let unhealthyConditionMarkers = ["service", "replace"]

    static func isUnhealthy(condition: String?) -> Bool {
        guard let condition, !condition.isEmpty else { return false }
        let normalized = condition.lowercased()
        return unhealthyConditionMarkers.contains { normalized.contains($0) }
    }

    mutating func evaluate(snapshot: BatteryHealthSnapshot?, now: Date) -> Bool {
        guard let snapshot else { return false }
        let isLowHealth = snapshot.healthPercent.map { $0 < Self.healthPercentThreshold } ?? false
        guard isLowHealth || Self.isUnhealthy(condition: snapshot.condition) else { return false }
        guard let lastFiredAt else {
            self.lastFiredAt = now
            return true
        }
        guard now.timeIntervalSince(lastFiredAt) >= Self.cooldown else { return false }
        self.lastFiredAt = now
        return true
    }
}

enum BatteryHealthParser {
    static func parse(data: Data) -> BatteryHealthSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let dictionaries = dictionaries(in: object)
        let condition = string(for: ["condition", "battery_health", "health"], in: dictionaries)
        let health = integer(for: ["maximum_capacity", "health_percent", "maximum_capacity_percent"], in: dictionaries)
        let cycles = integer(for: ["cycle_count", "cycles"], in: dictionaries)
        let current = integer(for: ["state_of_charge_percent", "state_of_charge", "battery_percent"], in: dictionaries)
        let charging = bool(for: ["charging", "is_charging"], in: dictionaries)

        guard condition != nil || health != nil || cycles != nil || current != nil || charging != nil else {
            return nil
        }
        return BatteryHealthSnapshot(
            condition: condition,
            healthPercent: health.map { min(max($0, 0), 100) },
            cycleCount: cycles.map { max($0, 0) },
            currentPercent: current.map { min(max($0, 0), 100) },
            isCharging: charging ?? false
        )
    }

    private static func dictionaries(in value: Any) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] {
            return [dictionary] + dictionary.values.flatMap(dictionaries(in:))
        }
        if let array = value as? [Any] {
            return array.flatMap(dictionaries(in:))
        }
        return []
    }

    private static func normalized(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func value(for keys: [String], in dictionaries: [[String: Any]]) -> Any? {
        let wanted = Set(keys.map(normalized))
        for dictionary in dictionaries {
            for (key, value) in dictionary where wanted.contains(normalized(key)) {
                return value
            }
        }
        return nil
    }

    private static func string(for keys: [String], in dictionaries: [[String: Any]]) -> String? {
        guard let value = value(for: keys, in: dictionaries) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func integer(for keys: [String], in dictionaries: [[String: Any]]) -> Int? {
        guard let value = value(for: keys, in: dictionaries) else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String {
            let cleaned = string.filter { $0.isNumber || $0 == "." }
            return Double(cleaned).map { Int($0.rounded()) }
        }
        return nil
    }

    private static func bool(for keys: [String], in dictionaries: [[String: Any]]) -> Bool? {
        guard let string = string(for: keys, in: dictionaries)?.lowercased() else { return nil }
        if ["yes", "true", "charging", "1"].contains(string) { return true }
        if ["no", "false", "not charging", "0"].contains(string) { return false }
        return nil
    }
}

protocol BatteryHealthProviding: Sendable {
    func read() -> BatteryHealthSnapshot?
}

struct DefaultBatteryHealthProvider: BatteryHealthProviding {
    func read() -> BatteryHealthSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return BatteryHealthParser.parse(data: data)
    }
}

@MainActor
/// 电池健康告警冷却的持久化。
///
/// 与资源告警同一套思路：冷却存偏好，重启后不会重复提醒同一件事（电池健康冷却 7 天，
/// 重启就重提醒尤其烦人）。键单独一个，避免和 CPU/内存/磁盘那三类的冷却字典混在一起。
enum BatteryHealthAlertCooldown {
    static let key = "systemResource.alerts.batteryHealth.lastFiredAt"

    static func load(from defaults: UserDefaults) -> Date? {
        guard let value = defaults.object(forKey: key) as? Double, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    static func save(_ date: Date?, to defaults: UserDefaults) {
        guard let date else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }
}

@MainActor
@Observable
final class BatteryHealthService {
    /// 面板每次打开都会重建视图，用单例保活已读到的快照，避免重复启动 system_profiler。
    static let shared = BatteryHealthService()

    private let provider: any BatteryHealthProviding
    private let alerter: any SystemResourceAlerting
    private let userDefaults: UserDefaults
    private let now: @Sendable () -> Date
    private(set) var snapshot: BatteryHealthSnapshot?
    private(set) var isLoading = false
    /// 电池健康告警：与资源告警共用「资源告警」总开关，桌面 Mac 上静默降级。
    private var alertPolicy = BatteryHealthAlertPolicy()

    init(
        provider: any BatteryHealthProviding = DefaultBatteryHealthProvider(),
        alerter: any SystemResourceAlerting = UserNotificationSystemResourceAlerter(),
        userDefaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.alerter = alerter
        self.userDefaults = userDefaults
        self.now = now
        alertPolicy.restoreLastFiredAt(BatteryHealthAlertCooldown.load(from: userDefaults))
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let provider = self.provider
        Task {
            snapshot = await Task.detached(priority: .utility) {
                provider.read()
            }.value
            isLoading = false
            evaluateAlert()
        }
    }

    /// 依据最新读数评估电池健康告警。
    ///
    /// - 与资源告警共用「资源告警」总开关（设置里同一个开关，避免多一个用户要理解的选项）；
    /// - 无电池（桌面 Mac）时快照为空或读数缺失，策略直接返回 false —— 静默降级；
    /// - 冷却写入偏好，重启后不会重复提醒同一件事。
    private func evaluateAlert() {
        let alertsEnabled = userDefaults.object(forKey: SystemResourceAlertSettings.enabledKey) as? Bool
            ?? SystemResourceAlertSettings.defaultEnabled
        guard alertsEnabled else { return }
        guard alertPolicy.evaluate(snapshot: snapshot, now: now()) else { return }
        alerter.send(.batteryHealth, snapshot: nil)
        BatteryHealthAlertCooldown.save(alertPolicy.lastFiredAt, to: userDefaults)
    }
}
