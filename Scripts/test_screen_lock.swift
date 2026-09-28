#!/usr/bin/swift
// 锁屏通道路径验证：macOS 26 起 User.menu 里的 CGSession 已被移除，
// 现行实现优先走 login.framework 的私有符号 SACLockScreenImmediate。
//
// 默认只探测、**不会锁屏**；要真的验证锁屏效果请显式加 --lock（会立即锁屏）。
import Foundation

let loginFrameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"
let legacyCGSessionPath = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"

print("=== 通道探测（只读，不会锁屏）===")

// 注意：login.framework 的二进制在 dyld 共享缓存里，文件路径通常不存在，但 dlopen 能成功。
print("login.framework 文件存在: \(FileManager.default.fileExists(atPath: loginFrameworkPath))（为 false 属正常）")

var loginSymbol: UnsafeMutableRawPointer?
if let handle = dlopen(loginFrameworkPath, RTLD_NOW) {
    print("dlopen login.framework: 成功")
    loginSymbol = dlsym(handle, "SACLockScreenImmediate")
    print("dlsym SACLockScreenImmediate: \(loginSymbol != nil ? "可解析" : "不可解析")")
} else {
    print("dlopen login.framework: 失败")
}

let legacyExists = FileManager.default.isExecutableFile(atPath: legacyCGSessionPath)
print("旧版 CGSession 可执行: \(legacyExists)")

let channel: String
if loginSymbol != nil {
    channel = "loginFramework（应用应选它）"
} else if legacyExists {
    channel = "legacyCGSession（应用应回退到它）"
} else {
    channel = "无可用通道 → 应用会给出「此系统没有可用的锁屏通道」"
}
print("结论: \(channel)")

guard CommandLine.arguments.contains("--lock") else {
    print("")
    print("（未执行锁屏。要实测请运行：swift Scripts/test_screen_lock.swift --lock）")
    exit(0)
}

print("")
print("=== 执行锁屏 ===")
guard let loginSymbol else {
    print("私有符号不可解析，无法用该通道锁屏")
    exit(1)
}
let lockScreen = unsafeBitCast(loginSymbol, to: (@convention(c) () -> Int32).self)
let status = lockScreen()
print("SACLockScreenImmediate 返回: \(status)（0 表示成功，屏幕应已锁定）")
exit(status == 0 ? 0 : 1)
