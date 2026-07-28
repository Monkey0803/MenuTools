import Foundation
import IOBluetooth
import IOKit

/// 一台蓝牙设备的电量信息
/// 耳机类设备携带左耳 / 右耳 / 充电盒分量；键盘、鼠标、头戴耳机等为单电池（singlePercent）
struct BluetoothDeviceBattery: Identifiable, Equatable {
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

/// 蓝牙设备电量采集（两条通道合并）：
/// 1. IORegistry：AppleDeviceManagementHIDEventService（AirPods 的 Left/Right/Case）
/// 2. IOBluetooth 私有 getter（IOBluetoothDeviceExpansion 分类，经典蓝牙 HFP 耳机等）；
///    键名来自 SDK tbd 符号表，本机实测 WH-1000XM3 返回 batteryPercentSingle=70
enum BluetoothBatteryService {

    static func fetch() -> [BluetoothDeviceBattery] {
        let registry = fetchFromRegistry()
        let classic = fetchFromIOBluetooth()
        var merged = registry
        let existingNames = Set(registry.map(\.name))
        merged += classic.filter { !existingNames.contains($0.name) }
        // 耳机类排前面，其余按名称排序
        return merged.sorted {
            if $0.isHeadset != $1.isHeadset { return $0.isHeadset }
            return $0.name < $1.name
        }
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
