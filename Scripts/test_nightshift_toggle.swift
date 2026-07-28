#!/usr/bin/swift
// 夜览开关往返测试：读 enabled -> 翻转 -> 再读（应变化）-> 还原
import Foundation

_ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
let cls = NSClassFromString("CBBlueLightClient") as! NSObject.Type
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

typealias GetStatusFunc = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
typealias SetEnabledFunc = @convention(c) (AnyObject, Selector, Bool) -> Bool

let getSel = Selector(("getBlueLightStatus:"))
let setSel = Selector(("setEnabled:"))
let getFn = unsafeBitCast(client.method(for: getSel), to: GetStatusFunc.self)
let setFn = unsafeBitCast(client.method(for: setSel), to: SetEnabledFunc.self)

func readEnabled() -> Bool {
    var status = BlueLightStatus()
    _ = withUnsafeMutablePointer(to: &status) { getFn(client, getSel, UnsafeMutableRawPointer($0)) }
    return status.enabled.boolValue
}

let before = readEnabled()
print("初始 enabled=\(before)")
let setOK = setFn(client, setSel, !before)
Thread.sleep(forTimeInterval: 0.5)
let after = readEnabled()
print("翻转后 setOK=\(setOK) enabled=\(after)")
_ = setFn(client, setSel, before)
Thread.sleep(forTimeInterval: 0.5)
print("还原后 enabled=\(readEnabled())")
print(after != before ? "PASS: enabled 字段映射正确，setEnabled 生效" : "FAIL: 状态未变化")
