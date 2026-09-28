#!/usr/bin/swift
// 内存指标口径验证：复核「已用 = 活跃 + 常驻 + 压缩」与内核压力信号映射。
// 同时打印旧口径（total - free）作为对照，说明它为什么必然虚高。
import Foundation

func pageSize() -> Int64 {
    var size: vm_size_t = 0
    host_page_size(mach_host_self(), &size)
    return Int64(size)
}

func pressureLevel() -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.stride
    guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
        return nil
    }
    return Int(value)
}

func pressureName(_ level: Int?) -> String {
    switch level {
    case 1: return "normal（正常）"
    case 2: return "warning（警告）"
    case 4: return "critical（危急）"
    case let other?: return "未知取值 \(other) → 回退到比例判定"
    case nil: return "读不到 → 回退到比例判定"
    }
}

func mb(_ bytes: Int64) -> String {
    String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
}

var info = vm_statistics64()
var count = mach_msg_type_number_t(
    MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
)
let result = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
    }
}
guard result == KERN_SUCCESS else {
    print("host_statistics64 读取失败")
    exit(1)
}

let page = pageSize()
let total = Int64(ProcessInfo.processInfo.physicalMemory)
let wired = Int64(info.wire_count) * page
let active = Int64(info.active_count) * page
let compressed = Int64(info.compressor_page_count) * page
let cached = Int64(info.inactive_count) * page
let free = (Int64(info.free_count) + Int64(info.speculative_count)) * page
let used = wired + active + compressed

print("物理内存 total      = \(mb(total))（页大小 \(page) 字节）")
print("")
print("分区明细：")
print("  wired 常驻        = \(mb(wired))")
print("  active 活跃       = \(mb(active))")
print("  compressed 压缩   = \(mb(compressed))")
print("  cached 非活跃缓存 = \(mb(cached))")
print("  free 空闲(含 spec)= \(mb(free))")
print("  purgeable         = \(mb(Int64(info.purgeable_count) * page))（与上面各项重叠，不单独计入）")
print("  speculative       = \(mb(Int64(info.speculative_count) * page))")
print("")
print("新口径 used = wired + active + compressed = \(mb(used))")
print(String(format: "  已用比例 = %.1f%%", Double(used) / Double(total) * 100))
print("旧口径 used = total - free               = \(mb(total - (Int64(info.free_count) * page)))")
print(String(format: "  已用比例 = %.1f%%  ← 把文件缓存算成已用，必然虚高",
             Double(total - (Int64(info.free_count) * page)) / Double(total) * 100))
print("")
print("分区求和校验：wired + active + compressed + cached + free = \(mb(wired + active + compressed + cached + free))")
print(String(format: "  与物理内存偏差 = %.1f%%（偏差小说明口径互补、无重复计数）",
             abs(Double(wired + active + compressed + cached + free) - Double(total)) / Double(total) * 100))
print("")
let level = pressureLevel()
print("内核压力信号 kern.memorystatus_vm_pressure_level = \(level.map(String.init) ?? "读取失败")")
print("  应用内映射为：\(pressureName(level))")
