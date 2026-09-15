#!/usr/bin/swift
// 验证 IOAccelerator 的 PerformanceStatistics 是否能读到 GPU 占用（只读）
import Foundation
import IOKit

guard let matching = IOServiceMatching("IOAccelerator") else {
    print("FAIL: 无法构造 IOAccelerator 匹配")
    exit(1)
}
var iterator: io_iterator_t = 0
guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
    print("UNSUPPORTED: 枚举 IOAccelerator 失败")
    exit(2)
}
defer { IOObjectRelease(iterator) }

var reports: [String] = []
while case let service = IOIteratorNext(iterator), service != 0 {
    defer { IOObjectRelease(service) }
    guard let statistics = IORegistryEntryCreateCFProperty(
        service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
    )?.takeRetainedValue() as? [String: Any] else { continue }
    let utilizationKeys = statistics.keys.filter {
        $0.localizedCaseInsensitiveContains("utilization") || $0.localizedCaseInsensitiveContains("activity")
    }
    for key in utilizationKeys.sorted() {
        let value = statistics[key] ?? "?"
        reports.append("\(key) = \(value)")
    }
}

if reports.isEmpty {
    print("UNSUPPORTED: 没有可用的 GPU 占用字段")
    exit(2)
}
for report in reports {
    print("OK \(report)")
}
exit(0)
