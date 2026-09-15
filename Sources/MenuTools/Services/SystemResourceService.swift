import Darwin
import Foundation
import IOKit
import Observation

/// CPU 计数器快照；CPU 使用率由相邻两次快照的差值计算。
struct SystemResourceCPUTicks: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

/// 单个 CPU 核心的使用率。
struct SystemResourceCoreUsage: Equatable, Sendable {
    let index: Int
    let usage: Double
}

/// 内存分区明细（字节）。
struct SystemResourceMemoryDetail: Equatable, Sendable {
    let wiredBytes: Int64
    let activeBytes: Int64
    let compressedBytes: Int64
    let cachedBytes: Int64
    let freeBytes: Int64
    let totalBytes: Int64
}

/// 一次系统资源原始读数。
struct SystemResourceReading: Equatable, Sendable {
    let timestamp: TimeInterval
    let cpuTicks: SystemResourceCPUTicks
    let memoryUsedBytes: Int64
    let memoryTotalBytes: Int64
    let diskAvailableBytes: Int64
    let diskTotalBytes: Int64
    let networkReceivedBytes: Int64
    let networkSentBytes: Int64
    /// 每核 CPU 计数器（长度等于核心数）。
    var coreTicks: [SystemResourceCPUTicks] = []
    /// 内存分区明细的原始页数换算结果。
    var memoryWiredBytes: Int64 = 0
    var memoryActiveBytes: Int64 = 0
    var memoryCompressedBytes: Int64 = 0
    var memoryCachedBytes: Int64 = 0
    var memoryFreeBytes: Int64 = 0
    /// 磁盘累计读写字节（跨所有块设备驱动求和）。
    var diskReadBytes: Int64 = 0
    var diskWrittenBytes: Int64 = 0
}

enum SystemMemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical

    var shouldOfferMemoryRelease: Bool {
        self == .critical
    }
}

/// 展示层使用的系统资源快照。
struct SystemResourceSnapshot: Equatable, Sendable {
    let cpuUsage: Double
    let memoryUsedBytes: Int64
    let memoryTotalBytes: Int64
    let memoryPressure: SystemMemoryPressure
    let diskAvailableBytes: Int64
    let diskTotalBytes: Int64
    let networkDownloadBytesPerSecond: Int64
    let networkUploadBytesPerSecond: Int64
    /// 每核使用率（无数据时为空）。
    var coreUsages: [SystemResourceCoreUsage] = []
    /// 内存分区明细；数据源不可用时为 nil。
    var memoryDetail: SystemResourceMemoryDetail?
    var diskReadBytesPerSecond: Int64 = 0
    var diskWriteBytesPerSecond: Int64 = 0
}

/// 将系统原始读数转换为稳定的 UI 快照。
enum SystemResourceCalculator {
    static func snapshot(
        current: SystemResourceReading,
        previous: SystemResourceReading?
    ) -> SystemResourceSnapshot {
        let cpuUsage: Double
        let downloadRate: Int64
        let uploadRate: Int64
        let diskReadRate: Int64
        let diskWriteRate: Int64
        var perCoreUsages: [SystemResourceCoreUsage] = []

        if let previous {
            let elapsed = max(current.timestamp - previous.timestamp, 0.001)
            let user = delta(current.cpuTicks.user, previous.cpuTicks.user)
            let system = delta(current.cpuTicks.system, previous.cpuTicks.system)
            let idle = delta(current.cpuTicks.idle, previous.cpuTicks.idle)
            let nice = delta(current.cpuTicks.nice, previous.cpuTicks.nice)
            let total = user + system + idle + nice
            cpuUsage = total == 0 ? 0 : min(max(Double(user + system + nice) / Double(total), 0), 1)
            downloadRate = rate(delta(current.networkReceivedBytes, previous.networkReceivedBytes), elapsed)
            uploadRate = rate(delta(current.networkSentBytes, previous.networkSentBytes), elapsed)
            diskReadRate = rate(delta(current.diskReadBytes, previous.diskReadBytes), elapsed)
            diskWriteRate = rate(delta(current.diskWrittenBytes, previous.diskWrittenBytes), elapsed)
            perCoreUsages = coreUsages(current: current, previous: previous)
        } else {
            cpuUsage = 0
            downloadRate = 0
            uploadRate = 0
            diskReadRate = 0
            diskWriteRate = 0
        }

        let memoryTotal = max(current.memoryTotalBytes, 0)
        let memoryUsed = min(max(current.memoryUsedBytes, 0), memoryTotal)
        let memoryRatio = memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal)
        let memoryPressure: SystemMemoryPressure
        switch memoryRatio {
        case 0.9...:
            memoryPressure = .critical
        case 0.75...:
            memoryPressure = .warning
        default:
            memoryPressure = .normal
        }

        return SystemResourceSnapshot(
            cpuUsage: cpuUsage,
            memoryUsedBytes: memoryUsed,
            memoryTotalBytes: memoryTotal,
            memoryPressure: memoryPressure,
            diskAvailableBytes: max(current.diskAvailableBytes, 0),
            diskTotalBytes: max(current.diskTotalBytes, 0),
            networkDownloadBytesPerSecond: downloadRate,
            networkUploadBytesPerSecond: uploadRate,
            coreUsages: perCoreUsages,
            memoryDetail: memoryDetail(current),
            diskReadBytesPerSecond: diskReadRate,
            diskWriteBytesPerSecond: diskWriteRate
        )
    }

    /// 每核使用率：按核心下标与上一次读数配对；数量不一致时只算能对上的部分。
    private static func coreUsages(
        current: SystemResourceReading,
        previous: SystemResourceReading
    ) -> [SystemResourceCoreUsage] {
        let count = min(current.coreTicks.count, previous.coreTicks.count)
        guard count > 0 else { return [] }
        return (0 ..< count).compactMap { index in
            let now = current.coreTicks[index]
            let before = previous.coreTicks[index]
            let user = delta(now.user, before.user)
            let system = delta(now.system, before.system)
            let idle = delta(now.idle, before.idle)
            let nice = delta(now.nice, before.nice)
            let total = user + system + idle + nice
            guard total > 0 else { return nil }
            let usage = min(max(Double(user + system + nice) / Double(total), 0), 1)
            return SystemResourceCoreUsage(index: index, usage: usage)
        }
    }

    /// 内存分区明细：全部为 0 时视为数据源不可用。
    private static func memoryDetail(_ reading: SystemResourceReading) -> SystemResourceMemoryDetail? {
        let wired = max(reading.memoryWiredBytes, 0)
        let active = max(reading.memoryActiveBytes, 0)
        let compressed = max(reading.memoryCompressedBytes, 0)
        let cached = max(reading.memoryCachedBytes, 0)
        let free = max(reading.memoryFreeBytes, 0)
        guard wired + active + compressed + cached + free > 0 else { return nil }
        return SystemResourceMemoryDetail(
            wiredBytes: wired,
            activeBytes: active,
            compressedBytes: compressed,
            cachedBytes: cached,
            freeBytes: free,
            totalBytes: max(reading.memoryTotalBytes, 0)
        )
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private static func delta(_ current: Int64, _ previous: Int64) -> Int64 {
        current >= previous ? current - previous : 0
    }

    private static func rate(_ bytes: Int64, _ seconds: TimeInterval) -> Int64 {
        guard bytes > 0 else { return 0 }
        return Int64(Double(bytes) / seconds)
    }
}

/// 汇总 IOKit 块设备驱动统计里的累计读写字节。
enum SystemResourceDiskStatisticsParser {
    static let statisticsKey = "Statistics"
    static let bytesReadKey = "Bytes (Read)"
    static let bytesWrittenKey = "Bytes (Write)"

    /// 入参是每个驱动服务的 Statistics 字典；字段缺失或类型异常按 0 计。
    static func counters(fromStatistics statistics: [[String: Any]]) -> (read: Int64, written: Int64) {
        var read: Int64 = 0
        var written: Int64 = 0
        for entry in statistics {
            read += int64(entry[bytesReadKey])
            written += int64(entry[bytesWrittenKey])
        }
        return (read, written)
    }

    private static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let number as Int64: return max(number, 0)
        case let number as Int: return max(Int64(number), 0)
        case let number as UInt64: return number > UInt64(Int64.max) ? 0 : Int64(number)
        case let number as NSNumber: return max(number.int64Value, 0)
        default: return 0
        }
    }
}

protocol SystemResourceProviding: Sendable {
    func read() -> SystemResourceReading
}

struct DefaultSystemResourceProvider: SystemResourceProviding {
    func read() -> SystemResourceReading {
        let memory = memoryReading()
        let disk = diskReading()
        let network = networkReading()
        let memoryDetail = memoryDetailReading()
        let diskCounters = diskCounterReading()
        return SystemResourceReading(
            timestamp: ProcessInfo.processInfo.systemUptime,
            cpuTicks: cpuReading(),
            memoryUsedBytes: memory.used,
            memoryTotalBytes: memory.total,
            diskAvailableBytes: disk.available,
            diskTotalBytes: disk.total,
            networkReceivedBytes: network.received,
            networkSentBytes: network.sent,
            coreTicks: coreReadings(),
            memoryWiredBytes: memoryDetail.wired,
            memoryActiveBytes: memoryDetail.active,
            memoryCompressedBytes: memoryDetail.compressed,
            memoryCachedBytes: memoryDetail.cached,
            memoryFreeBytes: memoryDetail.free,
            diskReadBytes: diskCounters.read,
            diskWrittenBytes: diskCounters.written
        )
    }

    /// 每核 CPU 计数器。
    private func coreReadings() -> [SystemResourceCPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info, cpuCount > 0 else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }
        return (0 ..< Int(cpuCount)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            return SystemResourceCPUTicks(
                user: UInt64(info[base + Int(CPU_STATE_USER)]),
                system: UInt64(info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt64(info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    /// 内存分区明细，来自 vm_statistics64 的页数。
    private func memoryDetailReading() -> (wired: Int64, active: Int64, compressed: Int64, cached: Int64, free: Int64) {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0, 0, 0) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Int64(pageSize)
        return (
            Int64(info.wire_count) * page,
            Int64(info.active_count) * page,
            Int64(info.compressor_page_count) * page,
            (Int64(info.purgeable_count) + Int64(info.speculative_count)) * page,
            Int64(info.free_count) * page
        )
    }

    /// 磁盘累计读写字节：遍历块设备驱动服务的统计属性。
    private func diskCounterReading() -> (read: Int64, written: Int64) {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return (0, 0) }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var statistics: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(
                service,
                SystemResourceDiskStatisticsParser.statisticsKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            statistics.append(property)
        }
        return SystemResourceDiskStatisticsParser.counters(fromStatistics: statistics)
    }

    private func cpuReading() -> SystemResourceCPUTicks {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return SystemResourceCPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        }
        return SystemResourceCPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    private func memoryReading() -> (used: Int64, total: Int64) {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let freeBytes = Int64(info.free_count) * Int64(pageSize)
        return (max(total - freeBytes, 0), total)
    }

    private func diskReading() -> (available: Int64, total: Int64) {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys)
        return (
            max(values?.volumeAvailableCapacityForImportantUsage ?? 0, 0),
            max(Int64(values?.volumeTotalCapacity ?? 0), 0)
        )
    }

    private func networkReading() -> (received: Int64, sent: Int64) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return (0, 0) }
        defer { freeifaddrs(addresses) }

        var received: Int64 = 0
        var sent: Int64 = 0
        var current = addresses
        while let interface = current {
            let flags = interface.pointee.ifa_flags
            let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0
            if !isLoopback,
               let address = interface.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               let data = interface.pointee.ifa_data {
                let statistics = data.assumingMemoryBound(to: if_data.self).pointee
                received += Int64(statistics.ifi_ibytes)
                sent += Int64(statistics.ifi_obytes)
            }
            current = interface.pointee.ifa_next
        }
        return (received, sent)
    }
}

/// 资源采样节奏：面板可见时才按秒刷新；没有观察者且没开告警时不采样（省电）。
enum SystemResourceSamplingPolicy {
    /// 面板可见时的采样间隔。
    static let panelInterval: TimeInterval = 2
    /// 仅开启告警（面板关闭）时的采样间隔。
    static let alertInterval: TimeInterval = 10

    static func interval(liveObserverCount: Int, alertEnabled: Bool = false) -> TimeInterval? {
        if liveObserverCount > 0 { return panelInterval }
        if alertEnabled { return alertInterval }
        return nil
    }
}

/// 负责定时采样并向 SwiftUI 提供最新资源快照。
///
/// 用单例保活：面板每次打开都会重建视图，`@State` 新建实例会丢掉上一次读数，
/// 导致 CPU 速率首帧恒为 0。
@MainActor
@Observable
final class SystemResourceService {
    static let shared = SystemResourceService()

    private let provider: any SystemResourceProviding
    private let memoryReleaser: any SystemMemoryReleasing
    private var previousReading: SystemResourceReading?
    private var samplingTask: Task<Void, Never>?

    private(set) var snapshot: SystemResourceSnapshot?
    private(set) var isReleasingMemory = false
    private(set) var lastReleasedMemoryBytes: Int64?
    private(set) var lastMemoryReleaseResult: MemoryReleaseResult?

    var isMonitoring: Bool { samplingTask != nil }

    init(
        provider: any SystemResourceProviding = DefaultSystemResourceProvider(),
        memoryReleaser: any SystemMemoryReleasing = DefaultSystemMemoryReleaser()
    ) {
        self.provider = provider
        self.memoryReleaser = memoryReleaser
    }

    /// 开始按节奏采样（面板可见时调用；插件关闭时不应调用）。
    func beginMonitoring(
        interval: TimeInterval = SystemResourceSamplingPolicy.panelInterval
    ) {
        guard samplingTask == nil else { return }
        refresh()
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    /// 停止采样并清掉快照：插件关闭或面板关闭后不应残留读数。
    func endMonitoring() {
        samplingTask?.cancel()
        samplingTask = nil
        snapshot = nil
        previousReading = nil
    }

    func refresh() {
        let current = provider.read()
        snapshot = SystemResourceCalculator.snapshot(
            current: current,
            previous: previousReading
        )
        previousReading = current
    }

    @discardableResult
    func releaseMemory() -> MemoryReleaseResult? {
        guard !isReleasingMemory,
              snapshot?.memoryPressure.shouldOfferMemoryRelease == true else { return nil }
        isReleasingMemory = true
        let result = memoryReleaser.releaseMemory()
        lastMemoryReleaseResult = result
        lastReleasedMemoryBytes = result.processReleasedBytes
        refresh()
        isReleasingMemory = false
        return result
    }
}
