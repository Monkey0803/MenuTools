import Foundation
import IOBluetooth
import IOKit

/// 一台蓝牙设备的电量信息
/// 耳机类设备携带左耳 / 右耳 / 充电盒分量；键盘、鼠标、头戴耳机等为单电池（singlePercent）
struct BluetoothDeviceBattery: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let leftPercent: Int?
    let rightPercent: Int?
    let casePercent: Int?
    let singlePercent: Int?
    var isAudio: Bool = false

    var isHeadset: Bool {
        leftPercent != nil || rightPercent != nil || casePercent != nil
    }
}

/// 解析 system_profiler 的已连接蓝牙设备数据。该通道在 macOS 26 上能补齐
/// IOBluetooth 私有 getter 偶尔缺失的 AirPods 左耳、右耳或充电盒电量。
enum BluetoothSystemProfilerParser {
    static func parse(data: Data) -> [BluetoothDeviceBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else {
            return []
        }

        return sections.flatMap { section -> [BluetoothDeviceBattery] in
            guard let connected = section["device_connected"] as? [[String: Any]] else {
                return []
            }
            return connected.flatMap(parseConnectedDevices)
        }
    }

    private static func parseConnectedDevices(
        _ container: [String: Any]
    ) -> [BluetoothDeviceBattery] {
        container.compactMap { name, value in
            guard let properties = value as? [String: Any] else { return nil }

            let left = percent(properties["device_batteryLevelLeft"])
            let right = percent(properties["device_batteryLevelRight"])
            let box = percent(properties["device_batteryLevelCase"])
            let single = percent(properties["device_batteryLevel"])
                ?? percent(properties["device_batteryLevelMain"])

            guard left != nil || right != nil || box != nil || single != nil else {
                return nil
            }

            var device = BluetoothDeviceBattery(
                id: properties["device_address"] as? String ?? name,
                name: name,
                leftPercent: left,
                rightPercent: right,
                casePercent: box,
                singlePercent: single
            )
            let minorType = (properties["device_minorType"] as? String)?.lowercased() ?? ""
            device.isAudio = left != nil
                || right != nil
                || box != nil
                || minorType.contains("headphone")
                || minorType.contains("headset")
                || minorType.contains("earbud")
            return device
        }
    }

    private static func percent(_ value: Any?) -> Int? {
        let number: Int?
        if let value = value as? NSNumber {
            number = value.intValue
        } else if let value = value as? String {
            number = Int(value.filter(\.isNumber))
        } else {
            number = nil
        }
        guard let number, (0...100).contains(number) else { return nil }
        return number
    }
}

/// 按设备地址优先、名称兜底合并多个蓝牙数据源；已有字段优先，仅补齐缺失值。
enum BluetoothBatteryMerger {
    static func merge(
        primary: [BluetoothDeviceBattery],
        supplemental: [BluetoothDeviceBattery]
    ) -> [BluetoothDeviceBattery] {
        var result = primary
        for device in supplemental {
            guard let index = result.firstIndex(where: { matches($0, device) }) else {
                result.append(device)
                continue
            }
            let existing = result[index]
            result[index] = BluetoothDeviceBattery(
                id: existing.id,
                name: existing.name,
                leftPercent: existing.leftPercent ?? device.leftPercent,
                rightPercent: existing.rightPercent ?? device.rightPercent,
                casePercent: existing.casePercent ?? device.casePercent,
                singlePercent: existing.singlePercent ?? device.singlePercent,
                isAudio: existing.isAudio || device.isAudio
            )
        }
        return result
    }

    private static func matches(
        _ lhs: BluetoothDeviceBattery,
        _ rhs: BluetoothDeviceBattery
    ) -> Bool {
        let leftID = normalized(lhs.id)
        let rightID = normalized(rhs.id)
        if !leftID.isEmpty, leftID == rightID { return true }
        return normalized(lhs.name) == normalized(rhs.name)
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

protocol BluetoothSystemProfilerProviding: Sendable {
    func fetch() -> [BluetoothDeviceBattery]
}

struct DefaultBluetoothSystemProfilerProvider: BluetoothSystemProfilerProviding {
    func fetch() -> [BluetoothDeviceBattery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return BluetoothSystemProfilerParser.parse(data: data)
    }
}

/// 蓝牙设备电量采集（三条通道合并）：
/// 1. IORegistry：AppleDeviceManagementHIDEventService（AirPods 的 Left/Right/Case）
/// 2. IOBluetooth 私有 getter（IOBluetoothDeviceExpansion 分类，经典蓝牙 HFP 耳机等）；
///    键名来自 SDK tbd 符号表，本机实测 WH-1000XM3 返回 batteryPercentSingle=70
/// 3. system_profiler：补齐 macOS 26 上私有 getter 返回 0 的 AirPods 分量
enum BluetoothBatteryService {

    static func fetch(
        systemProfilerProvider: any BluetoothSystemProfilerProviding = DefaultBluetoothSystemProfilerProvider()
    ) async -> [BluetoothDeviceBattery] {
        let registry = fetchFromRegistry()
        let classic = fetchFromIOBluetooth()
        let profiler = await Task.detached(priority: .utility) {
            systemProfilerProvider.fetch()
        }.value
        let fastSources = BluetoothBatteryMerger.merge(primary: registry, supplemental: classic)
        let merged = BluetoothBatteryMerger.merge(primary: fastSources, supplemental: profiler)
        // 耳机类排前面，其余按名称排序
        let sorted = merged.sorted {
            if $0.isHeadset != $1.isHeadset { return $0.isHeadset }
            return $0.name < $1.name
        }
        return sorted
    }

    // MARK: - 通道 1：IORegistry

    private static func fetchFromRegistry() -> [BluetoothDeviceBattery] {
        var results: [BluetoothDeviceBattery] = []

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            let left = percent(props["BatteryPercentLeft"])
            let right = percent(props["BatteryPercentRight"])
            let box = percent(props["BatteryPercentCase"])
            let single = percent(props["BatteryPercent"])

            // 只保留至少读到一个电量的条目，过滤掉不上报电量的设备
            guard left != nil || right != nil || box != nil || single != nil else { continue }

            let name = (props["Product"] as? String)
                ?? (props["DeviceName"] as? String)
                ?? L("bt.device")
            let address = (props["DeviceAddress"] as? String) ?? name

            results.append(BluetoothDeviceBattery(
                id: address,
                name: name,
                leftPercent: left,
                rightPercent: right,
                casePercent: box,
                singlePercent: single
            ))
        }
        return results
    }

    // MARK: - 通道 2：IOBluetooth 私有 getter

    private static func fetchFromIOBluetooth() -> [BluetoothDeviceBattery] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        var results: [BluetoothDeviceBattery] = []
        for device in paired where device.isConnected() {
            let left = kvcPercent(device, "batteryPercentLeft")
            let right = kvcPercent(device, "batteryPercentRight")
            let box = kvcPercent(device, "batteryPercentCase")
            let single = kvcPercent(device, "batteryPercentSingle")
                ?? kvcPercent(device, "headsetBatteryPercent")

            guard left != nil || right != nil || box != nil || single != nil else { continue }

            var entry = BluetoothDeviceBattery(
                id: device.addressString ?? device.name ?? L("bt.device"),
                name: device.name ?? L("bt.device"),
                leftPercent: left,
                rightPercent: right,
                casePercent: box,
                singlePercent: single
            )
            entry.isAudio = device.deviceClassMajor == 0x04   // kBluetoothDeviceClassMajorAudio
            results.append(entry)
        }
        return results
    }

    /// 先确认 getter 存在再走 KVC，避免系统移除后抛 NSUnknownKeyException；0 视为未上报
    private static func kvcPercent(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: Selector((key))),
              let number = device.value(forKey: key) as? NSNumber else { return nil }
        let value = number.intValue
        return (1...100).contains(value) ? value : nil
    }

    /// 注册表中的电量值可能为 NSNumber；-1 或越界表示不可用
    private static func percent(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let percent = number.intValue
        return (0...100).contains(percent) ? percent : nil
    }
}
