#!/usr/bin/swift
// 验证 AppleSMC 私有 API 是否能读取温度（只读，不写入任何键）
import Foundation
import IOKit

struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }

struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

let kernelIndexSMC: UInt32 = 2
let readBytes: UInt8 = 5
let readKeyInfo: UInt8 = 9

func fourCharCode(_ value: String) -> UInt32 {
    value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

guard let matching = IOServiceMatching("AppleSMC") else {
    print("FAIL: 无法构造 AppleSMC 匹配")
    exit(1)
}
let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
guard service != 0 else {
    print("UNSUPPORTED: 找不到 AppleSMC 服务")
    exit(2)
}
defer { IOObjectRelease(service) }

var connection: io_connect_t = 0
guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
    print("UNSUPPORTED: 打不开 AppleSMC 连接")
    exit(2)
}
guard connection != 0 else {
    print("UNSUPPORTED: AppleSMC 连接为空")
    exit(2)
}
defer { IOServiceClose(connection) }

func call(_ input: inout SMCKeyData) -> SMCKeyData? {
    var output = SMCKeyData()
    var outputSize = MemoryLayout<SMCKeyData>.stride
    let result = IOConnectCallStructMethod(
        connection, kernelIndexSMC, &input,
        MemoryLayout<SMCKeyData>.stride, &output, &outputSize
    )
    guard result == KERN_SUCCESS, output.result == 0 else { return nil }
    return output
}

func keyInfo(_ key: String) -> SMCKeyInfoData? {
    var input = SMCKeyData()
    input.key = fourCharCode(key)
    input.data8 = readKeyInfo
    return call(&input)?.keyInfo
}

/// 把 sp78（有符号 7.8 定点）字节解成摄氏度。
func decodeSP78(_ bytes: (UInt8, UInt8)) -> Double? {
    let raw = Int16(bitPattern: UInt16(bytes.0) << 8 | UInt16(bytes.1))
    let value = Double(raw) / 256
    return value > -100 && value < 200 ? value : nil
}

func temperature(_ key: String) -> Double? {
    guard let info = keyInfo(key), info.dataSize > 0, info.dataSize <= 32 else { return nil }
    var input = SMCKeyData()
    input.key = fourCharCode(key)
    input.keyInfo.dataSize = info.dataSize
    input.data8 = readBytes
    guard let output = call(&input) else { return nil }
    return decodeSP78((output.bytes.0, output.bytes.1))
}

// 先确认 SMC 通道本身是否可用：读总键数 "#KEY"（Intel/Apple Silicon 通用）
do {
    var input = SMCKeyData()
    input.key = fourCharCode("#KEY")
    input.data8 = readKeyInfo
    if let info = call(&input)?.keyInfo {
        print("SMC #KEY keyInfo: size=\(info.dataSize) type=\(info.dataType)")
    } else {
        print("SMC #KEY 读取失败：通道不可用（键名之外的问题）")
    }
}

let candidates = ["TC0P", "TC0D", "TC0E", "TC0F", "Tp01", "Tp05", "Tp09", "Tp0D",
                  "Tp0b", "Tp0f", "Tg0P", "Tg0D", "Te05", "Te0L", "TB0T", "Ts0P"]
var found: [(String, Double)] = []
for key in candidates {
    if let value = temperature(key) {
        found.append((key, value))
    }
}
if found.isEmpty {
    print("UNSUPPORTED: 所有候选温度键都读不到（Apple Silicon 键名可能不同）")
    let info = keyInfo("TC0P")
    print("TC0P keyInfo: \(info.map { "size=\($0.dataSize) type=\($0.dataType)" } ?? "nil")")
    exit(2)
}
for (key, value) in found {
    print(String(format: "OK %@ = %.1f °C", key, value))
}
exit(0)
