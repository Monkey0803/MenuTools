#!/usr/bin/swift
// 探测 IOBluetoothDevice 私有电量属性（只读，不修改任何状态）
import Foundation
import IOBluetooth

let keys = ["batteryPercent", "batteryPercentSingle", "batteryPercentCombined",
            "batteryPercentLeft", "batteryPercentRight", "batteryPercentCase"]

guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
    print("无配对设备")
    exit(0)
}
for device in devices where device.isConnected() {
    let name = device.name ?? "?"
    var parts: [String] = []
    for key in keys {
        if let value = device.value(forKey: key) as? NSNumber {
            parts.append("\(key)=\(value)")
        }
    }
    print("\(name): \(parts.isEmpty ? "无电量属性" : parts.joined(separator: " "))")
}
