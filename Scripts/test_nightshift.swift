#!/usr/bin/swift
// 验证 CBBlueLightClient 私有 API 在当前系统可用（只读状态，不修改）
import Foundation

guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil else {
    print("FAIL: dlopen CoreBrightness 失败")
    exit(1)
}
guard let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else {
    print("FAIL: CBBlueLightClient 类不存在")
    exit(1)
}
let client = cls.init()

struct BlueLightStatus {
    var active: ObjCBool = false
    var enabled: ObjCBool = false
    var sunSchedulePermitted: ObjCBool = false
    var mode: Int32 = 0
    var schedule: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
    var disableFlags: UInt64 = 0
    var available: ObjCBool = false
}

let sel = Selector(("getBlueLightStatus:"))
guard client.responds(to: sel) else {
    print("FAIL: 不响应 getBlueLightStatus:")
    exit(1)
}
typealias GetStatusFunc = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
let fn = unsafeBitCast(client.method(for: sel), to: GetStatusFunc.self)
var status = BlueLightStatus()
let ok = withUnsafeMutablePointer(to: &status) { fn(client, sel, UnsafeMutableRawPointer($0)) }
print("call ok=\(ok) enabled=\(status.enabled.boolValue) active=\(status.active.boolValue) available=\(status.available.boolValue) mode=\(status.mode)")
print(client.responds(to: Selector(("setEnabled:"))) ? "setEnabled: 可用" : "FAIL: setEnabled: 不可用")
