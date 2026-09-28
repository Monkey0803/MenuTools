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
    /// GPU 占用（0…1）；系统不提供时为 nil。
    var gpuUsage: Double?
    /// 温度（摄氏度）；系统不提供时为 nil。
    var temperatureCelsius: Double?
    /// 内核内存压力信号（XNU：1 正常 / 2 警告 / 4 危急）；读不到时为 nil，由计算器回退到比例判定。
    var memoryPressureLevel: Int?
}

enum SystemMemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical

    /// 内核内存压力信号（`kern.memorystatus_vm_pressure_level`）到档位的映射。
    /// XNU 只定义 1 / 2 / 4，其他取值一律返回 nil，交由调用方回退，避免把未知值误判成危机。
    init?(kernelLevel: Int) {
        switch kernelLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }

    var shouldOfferMemoryRelease: Bool {
        self == .critical
    }
}

/// 内存口径换算。macOS 会把大量内存用作文件缓存，因此「已用」必须排除可回收部分，
/// 否则读数会长期贴近 100%（`total - free` 正是这种错误口径）。
enum SystemResourceMemoryBreakdown {
    /// 已用 = 活跃 + 常驻 + 压缩。
    static func usedBytes(wired: Int64, active: Int64, compressed: Int64) -> Int64 {
        max(wired, 0) + max(active, 0) + max(compressed, 0)
    }

    /// 读不到内核压力信号时的回退判据（沿用既有阈值）。
    static func pressure(used: Int64, total: Int64) -> SystemMemoryPressure {
        guard total > 0 else { return .normal }
        let ratio = Double(min(max(used, 0), total)) / Double(total)
        switch ratio {
        case 0.9...: return .critical
        case 0.75...: return .warning
        default: return .normal
        }
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
    /// GPU 占用（0…1）；系统不提供时为 nil。
    var gpuUsage: Double?
    /// 温度（摄氏度）；系统不提供时为 nil。
    var temperatureCelsius: Double?
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
        // 压力优先采用内核信号：已用比例会被文件缓存干扰，不足以判断真实压力。
        let memoryPressure = current.memoryPressureLevel
            .flatMap(SystemMemoryPressure.init(kernelLevel:))
            ?? SystemResourceMemoryBreakdown.pressure(used: memoryUsed, total: memoryTotal)

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
            diskWriteBytesPerSecond: diskWriteRate,
            gpuUsage: current.gpuUsage.map { min(max($0, 0), 1) },
            temperatureCelsius: current.temperatureCelsius
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
    private let optionalMetrics: any SystemResourceOptionalMetricsReading

    init(optionalMetrics: any SystemResourceOptionalMetricsReading = DefaultSystemResourceOptionalMetricsReader()) {
        self.optionalMetrics = optionalMetrics
    }

    func read() -> SystemResourceReading {
        let memory = memoryStatistics()
        let disk = diskReading()
        let network = networkReading()
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
            memoryWiredBytes: memory.wired,
            memoryActiveBytes: memory.active,
            memoryCompressedBytes: memory.compressed,
            memoryCachedBytes: memory.cached,
            memoryFreeBytes: memory.free,
            diskReadBytes: diskCounters.read,
            diskWrittenBytes: diskCounters.written,
            gpuUsage: optionalMetrics.readGPUUsage(),
            temperatureCelsius: optionalMetrics.readTemperatureCelsius(),
            memoryPressureLevel: memory.pressureLevel
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

    /// 一次 `vm_statistics64` 读取，供「已用」、分区明细与总量共用（此前分两次系统调用）。
    ///
    /// 口径约定：
    /// - 已用 = 活跃 + 常驻 + 压缩，**不含**文件缓存；
    /// - 「缓存」取非活跃页（文件缓存等可回收部分），与已用互补；
    /// - 空闲含 speculative，这样「常驻 + 活跃 + 压缩 + 缓存 + 空闲」才与总量对得上。
    private func memoryStatistics() -> (
        used: Int64,
        total: Int64,
        wired: Int64,
        active: Int64,
        compressed: Int64,
        cached: Int64,
        free: Int64,
        pressureLevel: Int?
    ) {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        let pressureLevel = memoryPressureLevel()
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
            return (0, total, 0, 0, 0, 0, 0, pressureLevel)
        }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Int64(pageSize)
        let wired = Int64(info.wire_count) * page
        let active = Int64(info.active_count) * page
        let compressed = Int64(info.compressor_page_count) * page
        let cached = Int64(info.inactive_count) * page
        let free = (Int64(info.free_count) + Int64(info.speculative_count)) * page
        return (
            SystemResourceMemoryBreakdown.usedBytes(wired: wired, active: active, compressed: compressed),
            total,
            wired,
            active,
            compressed,
            cached,
            free,
            pressureLevel
        )
    }

    /// 内核内存压力信号（`kern.memorystatus_vm_pressure_level`）；读不到时返回 nil。
    private func memoryPressureLevel() -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
            return nil
        }
        return Int(value)
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

/// 资源告警的设置键。
enum SystemResourceAlertSettings {
    static let enabledKey = "systemResource.alerts.enabled"
    static let cpuUsageKey = "systemResource.alerts.cpuUsage"
    static let cpuSustainSecondsKey = "systemResource.alerts.cpuSustainSeconds"
    static let diskFreeRatioKey = "systemResource.alerts.diskFreeRatio"
    static let defaultEnabled = true
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
    /// 是否已有一次采样在途：合并并发请求，避免积压。
    private var isSampling = false
    /// 采样代次：停止或换档后自增，用来丢弃在途的过期读数。
    private var samplingGeneration = 0
    private let memoryReleaser: any SystemMemoryReleasing
    private let historyStore: any SystemResourceHistoryStoring
    private let alerter: SystemResourceAlerting
    private let userDefaults: UserDefaults
    private var alertPolicy = SystemResourceAlertPolicy()

    /// 是否开启了资源告警。
    private(set) var alertsEnabled: Bool
    private(set) var alertThresholds: SystemResourceAlertThresholds
    private(set) var notificationPermission: SystemResourceNotificationPermission = .notRequested
    private var previousReading: SystemResourceReading?
    private var samplingTask: Task<Void, Never>?
    /// 面板可见时的高频采样开关。
    private var panelMonitoring = false
    /// 后台采样开关（菜单栏显示资源指标或开启告警时）。
    private var backgroundMonitoring = false
    private var panelInterval: TimeInterval = SystemResourceSamplingPolicy.panelInterval
    /// 当前采样档位，供自检与回归使用。
    private(set) var currentSamplingInterval: TimeInterval?
    /// 当前正在聚合的那一分钟。
    private var currentBucket: SystemResourceHistoryBucket?

    private(set) var snapshot: SystemResourceSnapshot?
    /// 已聚合的资源历史（按分钟一条）。
    private(set) var historyBuckets: [SystemResourceHistoryBucket] = []
    private(set) var isReleasingMemory = false
    private(set) var lastReleasedMemoryBytes: Int64?
    /// 最近一次系统文件缓存清理的结果；nil 表示还没试过。
    private(set) var lastSystemPurgeSucceeded: Bool?

    var isMonitoring: Bool { samplingTask != nil }

    init(
        provider: any SystemResourceProviding = DefaultSystemResourceProvider(),
        memoryReleaser: any SystemMemoryReleasing = DefaultSystemMemoryReleaser(),
        historyStore: any SystemResourceHistoryStoring = SystemResourceHistoryStore(),
        alerter: SystemResourceAlerting = UserNotificationSystemResourceAlerter(),
        userDefaults: UserDefaults = .standard
    ) {
        self.provider = provider
        self.memoryReleaser = memoryReleaser
        self.historyStore = historyStore
        self.alerter = alerter
        self.userDefaults = userDefaults
        alertsEnabled = userDefaults.object(forKey: SystemResourceAlertSettings.enabledKey) as? Bool
            ?? SystemResourceAlertSettings.defaultEnabled
        let storedCPU = userDefaults.object(forKey: SystemResourceAlertSettings.cpuUsageKey) as? Double
        let storedSustain = userDefaults.object(forKey: SystemResourceAlertSettings.cpuSustainSecondsKey) as? Double
        let storedDisk = userDefaults.object(forKey: SystemResourceAlertSettings.diskFreeRatioKey) as? Double
        alertThresholds = SystemResourceAlertThresholds(
            cpuUsage: storedCPU ?? 0.9,
            cpuSustainDuration: storedSustain ?? 5 * 60,
            diskFreeRatio: storedDisk ?? 0.1
        ).normalized()
    }

    /// 面板可见时的高频采样；面板关闭请调用 `endPanelMonitoring()`。
    func beginMonitoring(interval: TimeInterval = SystemResourceSamplingPolicy.panelInterval) {
        panelMonitoring = true
        panelInterval = interval
        updateSampling()
    }

    /// 面板关闭：回落到后台档；没有后台需求时完全停止。
    func endPanelMonitoring() {
        panelMonitoring = false
        updateSampling()
    }

    /// 后台采样：菜单栏显示资源指标或开启告警时为 true，按告警间隔省电采样。
    func setBackgroundMonitoring(_ enabled: Bool) {
        backgroundMonitoring = enabled
        updateSampling()
    }

    /// 按当前设置刷新后台采样需求（插件启动、告警开关变化、菜单栏选择变化时调用）。
    func refreshBackgroundSampling(userDefaults: UserDefaults = .standard) {
        let metric = userDefaults.string(forKey: SettingsKey.menuBarMetric)
            .flatMap(MenuBarMetric.init(rawValue:))
        let showsResourceMetric = metric == .cpu || metric == .memory || metric == .disk
        setBackgroundMonitoring(alertsEnabled || showsResourceMetric)
    }

    /// 完全停止采样（插件关闭或测试收尾），并清掉快照。
    func endMonitoring() {
        panelMonitoring = false
        backgroundMonitoring = false
        updateSampling()
    }

    private func updateSampling() {
        let interval: TimeInterval?
        if panelMonitoring {
            interval = panelInterval
        } else if backgroundMonitoring {
            interval = SystemResourceSamplingPolicy.alertInterval
        } else {
            interval = nil
        }

        guard interval != currentSamplingInterval || samplingTask == nil else { return }
        samplingTask?.cancel()
        samplingTask = nil
        currentSamplingInterval = interval
        // 换档或停止后，在途采样的结果必须作废，否则停用后还会回填一份旧快照。
        samplingGeneration &+= 1
        isSampling = false
        guard let interval else {
            snapshot = nil
            previousReading = nil
            flushHistory()
            return
        }

        refreshInBackground()
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.refreshInBackground()
            }
        }
    }

    /// 后台采样：读取（IOKit / getifaddrs / 进程枚举）放到主线程之外。
    ///
    /// 面板打开时每 2 秒一次、菜单栏显示资源指标时每 10 秒一次；同步在主线程做这些读取
    /// 会直接卡住面板滚动与菜单栏标题刷新，磁盘慢的时候尤其明显。
    func refreshInBackground(now: Date = Date()) {
        // 上一次还没读完就跳过本次请求，避免高频档下请求积压。
        guard !isSampling else { return }
        isSampling = true
        let provider = self.provider
        let generation = samplingGeneration
        Task { [weak self] in
            let current = await Task.detached(priority: .utility) { provider.read() }.value
            guard let self else { return }
            // 采样已停止或已换档：丢掉这次在途读数。
            guard generation == self.samplingGeneration else { return }
            self.isSampling = false
            self.applyReading(current, now: now)
        }
    }

    /// 同步采样：读取在主线程完成，只用于测试与需要立刻拿到结果的场景。
    func refresh(now: Date = Date()) {
        applyReading(provider.read(), now: now)
    }

    private func applyReading(_ current: SystemResourceReading, now: Date) {
        snapshot = SystemResourceCalculator.snapshot(
            current: current,
            previous: previousReading
        )
        previousReading = current
        recordHistory(now: now)
        evaluateAlerts(now: now)
    }

    // MARK: - 告警

    func setAlertsEnabled(_ enabled: Bool) {
        alertsEnabled = enabled
        userDefaults.set(enabled, forKey: SystemResourceAlertSettings.enabledKey)
        refreshBackgroundSampling(userDefaults: userDefaults)
        if enabled, notificationPermission == .notRequested {
            requestNotificationPermission()
        }
    }

    func setAlertThresholds(_ thresholds: SystemResourceAlertThresholds) {
        alertThresholds = thresholds.normalized()
        userDefaults.set(alertThresholds.cpuUsage, forKey: SystemResourceAlertSettings.cpuUsageKey)
        userDefaults.set(
            alertThresholds.cpuSustainDuration,
            forKey: SystemResourceAlertSettings.cpuSustainSecondsKey
        )
        userDefaults.set(alertThresholds.diskFreeRatio, forKey: SystemResourceAlertSettings.diskFreeRatioKey)
    }

    func requestNotificationPermission() {
        guard alertsEnabled else { return }
        alerter.requestPermission()
        Task { [weak self] in
            await self?.refreshNotificationPermission()
        }
    }

    func refreshNotificationPermission() async {
        let permission = await alerter.currentPermission()
        guard notificationPermission != permission else { return }
        notificationPermission = permission
    }

    /// 采样后评估告警；只在开启且拿到快照时才判定。
    func evaluateAlerts(now: Date = Date()) {
        guard alertsEnabled, let snapshot else { return }
        let fired = alertPolicy.evaluate(snapshot: snapshot, now: now, thresholds: alertThresholds)
        for kind in fired {
            alerter.send(kind, snapshot: snapshot)
        }
    }

    /// 按分钟聚合历史：同一分钟只在内存里取平均，分钟切换时才写库（避免每 2 秒写一次）。
    func recordHistory(now: Date = Date()) {
        guard let snapshot else { return }
        let bucketDate = SystemResourceHistoryAggregator.bucketTimestamp(for: now)
        if let currentBucket, currentBucket.timestamp == bucketDate {
            self.currentBucket = SystemResourceHistoryAggregator.merging(
                existing: currentBucket,
                snapshot: snapshot,
                timestamp: bucketDate
            )
            upsertHistory(self.currentBucket)
            return
        }
        flushHistory()
        currentBucket = SystemResourceHistoryAggregator.merging(
            existing: nil,
            snapshot: snapshot,
            timestamp: bucketDate
        )
        upsertHistory(currentBucket)
    }

    /// 把当前聚合中的桶写库（分钟切换、停止监控、退出时调用）。
    func flushHistory(now: Date = Date()) {
        guard let currentBucket else { return }
        self.currentBucket = nil
        historyStore.save(SystemResourceHistoryAggregator.pruned(
            [currentBucket],
            now: now
        ))
    }

    /// 读取最近的历史（首次调用会从库里加载，供趋势图与设置页使用）。
    @discardableResult
    func loadHistory(now: Date = Date()) -> [SystemResourceHistoryBucket] {
        let since = now.addingTimeInterval(-SystemResourceHistoryAggregator.retentionInterval)
        let stored = historyStore.load(since: since)
        var merged = stored
        if let currentBucket, !merged.contains(where: { $0.timestamp == currentBucket.timestamp }) {
            merged.append(currentBucket)
        }
        historyBuckets = merged.sorted { $0.timestamp < $1.timestamp }
        return historyBuckets
    }

    func clearHistory() {
        currentBucket = nil
        historyBuckets = []
        historyStore.clearAll()
    }

    var historyStorageUsage: SystemResourceHistoryStorageUsage {
        historyStore.storageUsage()
    }

    private func upsertHistory(_ bucket: SystemResourceHistoryBucket?) {
        guard let bucket else { return }
        if let index = historyBuckets.firstIndex(where: { $0.timestamp == bucket.timestamp }) {
            historyBuckets[index] = bucket
        } else {
            historyBuckets.append(bucket)
            historyBuckets.sort { $0.timestamp < $1.timestamp }
        }
    }

    /// 面板的释放入口是否该出现：只在内存压力临界时提供。
    var shouldOfferMemoryRelease: Bool {
        snapshot?.memoryPressure.shouldOfferMemoryRelease == true
    }

    /// 一键回收：只回收本进程分配器缓存，不需要权限，**不会弹出任何授权对话框**。
    @discardableResult
    func relieveProcessMemory() -> Int64 {
        guard !isReleasingMemory else { return 0 }
        isReleasingMemory = true
        let released = memoryReleaser.relieveProcessMemory()
        lastReleasedMemoryBytes = released
        refresh()
        isReleasingMemory = false
        return released
    }

    /// 清理系统文件缓存：需要管理员授权，会弹一次授权对话框；取消即返回 false。
    @discardableResult
    func purgeSystemCache() -> Bool {
        let succeeded = memoryReleaser.purgeSystemCache()
        lastSystemPurgeSucceeded = succeeded
        refresh()
        return succeeded
    }
}
