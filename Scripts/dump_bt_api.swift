#!/usr/bin/swift
// 运行时反射：枚举 IOBluetoothDevice 及相关类的全部方法/属性，找电量相关 API
import Foundation
import IOBluetooth
import ObjectiveC

func dumpBattery(cls: AnyClass) {
    var found: [String] = []
    // 实例方法
    var count: UInt32 = 0
    if let methods = class_copyMethodList(cls, &count) {
        for i in 0..<Int(count) {
            let name = NSStringFromSelector(method_getName(methods[i]))
            if name.lowercased().contains("batt") { found.append("method: \(name)") }
        }
        free(methods)
    }
    // 属性
    var pCount: UInt32 = 0
    if let props = class_copyPropertyList(cls, &pCount) {
        for i in 0..<Int(pCount) {
            let name = String(cString: property_getName(props[i]))
            if name.lowercased().contains("batt") { found.append("property: \(name)") }
        }
        free(props)
    }
    print("\(cls): \(found.isEmpty ? "无 batt 相关成员" : "")")
    found.forEach { print("  \($0)") }
}

dumpBattery(cls: IOBluetoothDevice.self)
if let hc = NSClassFromString("IOBluetoothHostController") { dumpBattery(cls: hc) }

// 顺带枚举系统中所有名字含 Bluetooth 且有 batt 成员的类
print("\n=== 全局扫描含 batt 成员的 Bluetooth 类 ===")
var classCount: UInt32 = 0
if let classList = objc_copyClassList(&classCount) {
    for i in 0..<Int(classCount) {
        let cls: AnyClass = classList[i]
        let name = NSStringFromClass(cls)
        guard name.contains("Bluetooth") || name.hasPrefix("BT") || name.hasPrefix("CB") else { continue }
        var mCount: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &mCount) else { continue }
        var hits: [String] = []
        for j in 0..<Int(mCount) {
            let sel = NSStringFromSelector(method_getName(methods[j]))
            if sel.lowercased().contains("batt") { hits.append(sel) }
        }
        free(methods)
        if !hits.isEmpty {
            print("\(name):")
            hits.prefix(8).forEach { print("  \($0)") }
        }
    }
}
