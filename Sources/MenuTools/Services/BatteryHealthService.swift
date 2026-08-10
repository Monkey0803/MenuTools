import Foundation
import Observation

struct BatteryHealthSnapshot: Equatable, Sendable {
    let condition: String?
    let healthPercent: Int?
    let cycleCount: Int?
    let currentPercent: Int?
    let isCharging: Bool
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
@Observable
final class BatteryHealthService {
    private let provider: any BatteryHealthProviding
    private(set) var snapshot: BatteryHealthSnapshot?
    private(set) var isLoading = false

    init(provider: any BatteryHealthProviding = DefaultBatteryHealthProvider()) {
        self.provider = provider
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
        }
    }
}
