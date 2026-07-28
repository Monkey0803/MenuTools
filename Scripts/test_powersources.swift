#!/usr/bin/swift
// 探测 IOPowerSources 中的外设电量（系统电池菜单同款数据源，只读）
import Foundation
import IOKit.ps

guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
    print("无电源信息")
    exit(0)
}
print("共 \(sources.count) 个电源条目")
for source in sources {
    guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
    print("---")
    for (key, value) in info.sorted(by: { $0.key < $1.key }) {
        print("  \(key) = \(value)")
    }
}
