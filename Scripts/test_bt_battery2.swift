#!/usr/bin/swift
// 用 TBD 符号表中确认存在的键名重测 IOBluetoothDevice 电量（只读）
import Foundation
import IOBluetooth

let keys = ["batteryPercentSingle", "batteryPercentCombined", "headsetBatteryPercent",
            "batteryPercentLeft", "batteryPercentRight", "batteryPercentCase"]

guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
    print("无配对设备"); exit(0)
}
for device in devices where device.isConnected() {
    let name = device.name ?? "?"
    var parts: [String] = []
    for key in keys {
        // 先确认 getter 存在再走 KVC，避免 NSUnknownKeyException
        guard device.responds(to: Selector((key))) else { continue }
        if let value = device.value(forKey: key) as? NSNumber {
            parts.append("\(key)=\(value)")
        }
    }
    print("\(name): \(parts.isEmpty ? "无可用电量 getter" : parts.joined(separator: "  "))")
}
