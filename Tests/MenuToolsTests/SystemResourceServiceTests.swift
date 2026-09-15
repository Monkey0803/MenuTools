import Foundation
import Testing
@testable import MenuTools

private struct RecordingMemoryReleaser: SystemMemoryReleasing {
    let releasedBytes: Int64
    let recorder: ReleaseRecorder

    func releaseMemory() -> MemoryReleaseResult {
        recorder.callCount += 1
        return MemoryReleaseResult(systemCachePurged: true, processReleasedBytes: releasedBytes)
    }
}

private final class ReleaseRecorder: @unchecked Sendable {
    var callCount = 0
}

private func reading(
    time: TimeInterval,
    ticks: SystemResourceCPUTicks,
    memoryUsed: Int64 = 4_000,
    memoryTotal: Int64 = 8_000,
    diskAvailable: Int64 = 20_000,
    diskTotal: Int64 = 100_000,
    received: Int64 = 1_000,
    sent: Int64 = 2_000
) -> SystemResourceReading {
    SystemResourceReading(
        timestamp: time,
        cpuTicks: ticks,
        memoryUsedBytes: memoryUsed,
        memoryTotalBytes: memoryTotal,
        diskAvailableBytes: diskAvailable,
        diskTotalBytes: diskTotal,
        networkReceivedBytes: received,
        networkSentBytes: sent
    )
}

@Test("资源计算器在首帧不虚报 CPU 和网络速率")
func calculatorReturnsZeroRatesWithoutPreviousReading() {
    let current = reading(
        time: 10,
        ticks: SystemResourceCPUTicks(user: 10, system: 5, idle: 85, nice: 0)
    )

    let snapshot = SystemResourceCalculator.snapshot(current: current, previous: nil)

    #expect(snapshot.cpuUsage == 0)
    #expect(snapshot.networkDownloadBytesPerSecond == 0)
    #expect(snapshot.networkUploadBytesPerSecond == 0)
}

@Test("资源计算器根据 CPU 和网络计数器差值计算使用率")
func calculatorComputesRatesFromCounterDeltas() {
    let previous = reading(
        time: 10,
        ticks: SystemResourceCPUTicks(user: 10, system: 10, idle: 80, nice: 0)
    )
    let current = reading(
        time: 12,
        ticks: SystemResourceCPUTicks(user: 20, system: 20, idle: 100, nice: 0),
        received: 5_000,
        sent: 6_000
    )

    let snapshot = SystemResourceCalculator.snapshot(current: current, previous: previous)

    #expect(snapshot.cpuUsage == 0.5)
    #expect(snapshot.networkDownloadBytesPerSecond == 2_000)
    #expect(snapshot.networkUploadBytesPerSecond == 2_000)
}

@Test("资源计算器在计数器回退时将速率归零")
func calculatorClampsCounterResets() {
    let previous = reading(
        time: 10,
        ticks: SystemResourceCPUTicks(user: 100, system: 100, idle: 100, nice: 0),
        received: 5_000,
        sent: 5_000
    )
    let current = reading(
        time: 12,
        ticks: SystemResourceCPUTicks(user: 10, system: 10, idle: 10, nice: 0),
        received: 1_000,
        sent: 1_000
    )

    let snapshot = SystemResourceCalculator.snapshot(current: current, previous: previous)

    #expect(snapshot.cpuUsage == 0)
    #expect(snapshot.networkDownloadBytesPerSecond == 0)
    #expect(snapshot.networkUploadBytesPerSecond == 0)
}

@Test("资源计算器按内存使用比例分级压力")
func calculatorClassifiesMemoryPressure() {
    let normal = reading(
        time: 1,
        ticks: .init(user: 0, system: 0, idle: 1, nice: 0),
        memoryUsed: 5_000,
        memoryTotal: 10_000
    )
    let warning = reading(
        time: 1,
        ticks: .init(user: 0, system: 0, idle: 1, nice: 0),
        memoryUsed: 8_000,
        memoryTotal: 10_000
    )
    let critical = reading(
        time: 1,
        ticks: .init(user: 0, system: 0, idle: 1, nice: 0),
        memoryUsed: 9_500,
        memoryTotal: 10_000
    )

    #expect(SystemResourceCalculator.snapshot(current: normal, previous: nil).memoryPressure == .normal)
    #expect(SystemResourceCalculator.snapshot(current: warning, previous: nil).memoryPressure == .warning)
    #expect(SystemResourceCalculator.snapshot(current: critical, previous: nil).memoryPressure == .critical)
}

@Test("只有高内存压力时提供释放内存操作")
func memoryReleaseActionIsLimitedToCriticalPressure() {
    #expect(!SystemMemoryPressure.normal.shouldOfferMemoryRelease)
    #expect(!SystemMemoryPressure.warning.shouldOfferMemoryRelease)
    #expect(SystemMemoryPressure.critical.shouldOfferMemoryRelease)
}

@Test("高内存压力点击释放后调用系统释放器并保存结果")
@MainActor
func memoryReleaseRunsReleaserAndStoresResult() {
    let current = reading(
        time: 2,
        ticks: .init(user: 1, system: 1, idle: 1, nice: 0),
        memoryUsed: 9_500,
        memoryTotal: 10_000
    )
    let recorder = ReleaseRecorder()
    let service = SystemResourceService(
        provider: StubSystemResourceProvider(readings: [current, current]),
        memoryReleaser: RecordingMemoryReleaser(releasedBytes: 12_345, recorder: recorder)
    )

    service.refresh()
    service.releaseMemory()

    #expect(recorder.callCount == 1)
    #expect(service.lastMemoryReleaseResult == MemoryReleaseResult(
        systemCachePurged: true,
        processReleasedBytes: 12_345
    ))
    #expect(!service.isReleasingMemory)
}

private final class StubSystemResourceProvider: SystemResourceProviding, @unchecked Sendable {
    let readings: [SystemResourceReading]
    private var index = 0

    init(readings: [SystemResourceReading]) {
        self.readings = readings
    }

    func read() -> SystemResourceReading {
        defer { index += 1 }
        return readings[min(index, readings.count - 1)]
    }
}

/// 可控的假提供者，用来验证采样节奏与生命周期。
private final class CountingResourceProvider: SystemResourceProviding, @unchecked Sendable {
    private(set) var readCount = 0

    func read() -> SystemResourceReading {
        readCount += 1
        return SystemResourceReading(
            timestamp: 0,
            cpuTicks: SystemResourceCPUTicks(user: 1, system: 1, idle: 1, nice: 0),
            memoryUsedBytes: 1,
            memoryTotalBytes: 2,
            diskAvailableBytes: 3,
            diskTotalBytes: 4,
            networkReceivedBytes: 0,
            networkSentBytes: 0
        )
    }
}

@Test("资源采样分级：有观察者按面板间隔，仅告警按告警间隔，否则不采样")
func resourceSamplingPolicyIntervals() {
    #expect(SystemResourceSamplingPolicy.interval(liveObserverCount: 1) == 2)
    #expect(SystemResourceSamplingPolicy.interval(liveObserverCount: 3) == 2)
    #expect(SystemResourceSamplingPolicy.interval(liveObserverCount: 0, alertEnabled: true) == 10)
    #expect(SystemResourceSamplingPolicy.interval(liveObserverCount: 0) == nil)
}

@Test("开始监控会立刻采样，结束监控会停止并清掉快照")
@MainActor
func resourceMonitoringLifecycle() async throws {
    let provider = CountingResourceProvider()
    let service = SystemResourceService(provider: provider, memoryReleaser: NoopMemoryReleaser())

    #expect(!service.isMonitoring)
    #expect(service.snapshot == nil)

    service.beginMonitoring(interval: 60)
    #expect(service.isMonitoring)
    #expect(provider.readCount == 1)
    #expect(service.snapshot != nil)

    service.endMonitoring()
    #expect(!service.isMonitoring)
    // 结束时清掉快照，插件关闭后不应残留读数
    #expect(service.snapshot == nil)
}

private struct NoopMemoryReleaser: SystemMemoryReleasing {
    func releaseMemory() -> MemoryReleaseResult {
        MemoryReleaseResult(systemCachePurged: false, processReleasedBytes: 0)
    }
}

@Test("每核使用率按核心下标配对，计数器回退的核心不出现")
func calculatorComputesPerCoreUsage() {
    let previous = SystemResourceReading(
        timestamp: 0,
        cpuTicks: SystemResourceCPUTicks(user: 0, system: 0, idle: 0, nice: 0),
        memoryUsedBytes: 0,
        memoryTotalBytes: 0,
        diskAvailableBytes: 0,
        diskTotalBytes: 0,
        networkReceivedBytes: 0,
        networkSentBytes: 0,
        coreTicks: [
            SystemResourceCPUTicks(user: 0, system: 0, idle: 0, nice: 0),
            SystemResourceCPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        ]
    )
    let current = SystemResourceReading(
        timestamp: 1,
        cpuTicks: SystemResourceCPUTicks(user: 50, system: 0, idle: 50, nice: 0),
        memoryUsedBytes: 0,
        memoryTotalBytes: 0,
        diskAvailableBytes: 0,
        diskTotalBytes: 0,
        networkReceivedBytes: 0,
        networkSentBytes: 0,
        coreTicks: [
            // 核心 0：全忙
            SystemResourceCPUTicks(user: 100, system: 0, idle: 0, nice: 0),
            // 核心 1：一半忙
            SystemResourceCPUTicks(user: 50, system: 0, idle: 50, nice: 0)
        ]
    )

    let snapshot = SystemResourceCalculator.snapshot(current: current, previous: previous)

    #expect(snapshot.coreUsages.count == 2)
    #expect(snapshot.coreUsages[0].index == 0)
    #expect(abs(snapshot.coreUsages[0].usage - 1) < 0.001)
    #expect(abs(snapshot.coreUsages[1].usage - 0.5) < 0.001)
    #expect(abs(snapshot.cpuUsage - 0.5) < 0.001)
}

@Test("首帧没有上一次读数时不给每核使用率，避免虚报")
func calculatorSkipsPerCoreWithoutPreviousReading() {
    let current = SystemResourceReading(
        timestamp: 1,
        cpuTicks: SystemResourceCPUTicks(user: 10, system: 0, idle: 10, nice: 0),
        memoryUsedBytes: 0,
        memoryTotalBytes: 0,
        diskAvailableBytes: 0,
        diskTotalBytes: 0,
        networkReceivedBytes: 0,
        networkSentBytes: 0,
        coreTicks: [SystemResourceCPUTicks(user: 10, system: 0, idle: 10, nice: 0)]
    )

    let snapshot = SystemResourceCalculator.snapshot(current: current, previous: nil)

    #expect(snapshot.coreUsages.isEmpty)
}

@Test("内存分区明细换算成字节，全零时视为数据源不可用")
func calculatorReportsMemoryDetail() {
    let reading = SystemResourceReading(
        timestamp: 0,
        cpuTicks: SystemResourceCPUTicks(user: 0, system: 0, idle: 0, nice: 0),
        memoryUsedBytes: 8,
        memoryTotalBytes: 16,
        diskAvailableBytes: 0,
        diskTotalBytes: 0,
        networkReceivedBytes: 0,
        networkSentBytes: 0,
        memoryWiredBytes: 2,
        memoryActiveBytes: 3,
        memoryCompressedBytes: 1,
        memoryCachedBytes: 4,
        memoryFreeBytes: 6
    )

    let detail = try? #require(SystemResourceCalculator.snapshot(current: reading, previous: nil).memoryDetail)

    #expect(detail?.wiredBytes == 2)
    #expect(detail?.activeBytes == 3)
    #expect(detail?.compressedBytes == 1)
    #expect(detail?.cachedBytes == 4)
    #expect(detail?.freeBytes == 6)
    #expect(detail?.totalBytes == 16)

    // 全部为 0 → 明细不可用
    let empty = SystemResourceReading(
        timestamp: 0,
        cpuTicks: SystemResourceCPUTicks(user: 0, system: 0, idle: 0, nice: 0),
        memoryUsedBytes: 0,
        memoryTotalBytes: 16,
        diskAvailableBytes: 0,
        diskTotalBytes: 0,
        networkReceivedBytes: 0,
        networkSentBytes: 0
    )
    #expect(SystemResourceCalculator.snapshot(current: empty, previous: nil).memoryDetail == nil)
}

@Test("磁盘读写速率按差值计算，计数器回退归零")
func calculatorComputesDiskRates() {
    func reading(timestamp: TimeInterval, read: Int64, written: Int64) -> SystemResourceReading {
        SystemResourceReading(
            timestamp: timestamp,
            cpuTicks: SystemResourceCPUTicks(user: 0, system: 0, idle: 1, nice: 0),
            memoryUsedBytes: 0,
            memoryTotalBytes: 0,
            diskAvailableBytes: 0,
            diskTotalBytes: 0,
            networkReceivedBytes: 0,
            networkSentBytes: 0,
            diskReadBytes: read,
            diskWrittenBytes: written
        )
    }

    let first = reading(timestamp: 0, read: 1_000, written: 500)
    let second = reading(timestamp: 2, read: 5_000, written: 1_500)
    let snapshot = SystemResourceCalculator.snapshot(current: second, previous: first)

    #expect(snapshot.diskReadBytesPerSecond == 2_000)
    #expect(snapshot.diskWriteBytesPerSecond == 500)

    // 计数器回退（设备被替换）时归零而不是负数
    let rolledBack = reading(timestamp: 3, read: 10, written: 10)
    let reset = SystemResourceCalculator.snapshot(current: rolledBack, previous: second)
    #expect(reset.diskReadBytesPerSecond == 0)
    #expect(reset.diskWriteBytesPerSecond == 0)
}

@Test("IOKit 磁盘统计会跨驱动求和，字段异常按 0 计")
func diskStatisticsParserSumsDrivers() {
    let statistics: [[String: Any]] = [
        ["Bytes (Read)": 1_000, "Bytes (Write)": 500],
        ["Bytes (Read)": NSNumber(value: 2_000), "Bytes (Write)": 250],
        ["Bytes (Read)": "not-a-number"],
        [:]
    ]

    let totals = SystemResourceDiskStatisticsParser.counters(fromStatistics: statistics)

    #expect(totals.read == 3_000)
    #expect(totals.written == 750)
    #expect(SystemResourceDiskStatisticsParser.counters(fromStatistics: []).read == 0)
}

@Test("真实数据源能读到核心数、内存与磁盘容量")
func defaultProviderReturnsHardwareReadings() {
    let reading = DefaultSystemResourceProvider().read()

    #expect(!reading.coreTicks.isEmpty)
    #expect(reading.memoryTotalBytes > 0)
    #expect(reading.diskTotalBytes > 0)
    #expect(reading.memoryFreeBytes > 0)
}

private func processSample(
    pid: pid_t,
    name: String = "proc",
    cpuNanoseconds: UInt64,
    memoryBytes: Int64 = 0,
    diskRead: Int64 = 0,
    diskWritten: Int64 = 0
) -> SystemProcessResourceSample {
    SystemProcessResourceSample(
        pid: pid,
        name: name,
        cpuTimeNanoseconds: cpuNanoseconds,
        memoryBytes: memoryBytes,
        diskReadBytes: diskRead,
        diskWrittenBytes: diskWritten
    )
}

@Test("进程占用按差值算速率，新进程与计数器回退都不虚报")
func processCalculatorComputesRates() {
    let previous = [
        processSample(pid: 1, name: "A", cpuNanoseconds: 0, memoryBytes: 100, diskRead: 0, diskWritten: 0),
        processSample(pid: 2, name: "B", cpuNanoseconds: 0, memoryBytes: 50, diskRead: 1_000, diskWritten: 0)
    ]
    let current = [
        // A 在 2 秒内用了 1 秒 CPU（半核）
        processSample(pid: 1, name: "A", cpuNanoseconds: 1_000_000_000, memoryBytes: 200, diskRead: 2_000, diskWritten: 1_000),
        // B 的磁盘计数器回退（进程重启）→ 速率归零
        processSample(pid: 2, name: "B", cpuNanoseconds: 0, memoryBytes: 60, diskRead: 10, diskWritten: 0),
        // C 是新进程 → 不出现（首帧不虚报）
        processSample(pid: 3, name: "C", cpuNanoseconds: 5_000_000_000, memoryBytes: 10)
    ]

    let usages = SystemProcessResourceCalculator.usages(current: current, previous: previous, elapsed: 2)

    #expect(usages.count == 2)
    let a = try? #require(usages.first { $0.pid == 1 })
    #expect(abs((a?.cpuUsage ?? 0) - 0.5) < 0.001)
    #expect(a?.diskReadBytesPerSecond == 1_000)
    #expect(a?.diskWrittenBytesPerSecond == 500)
    #expect(a?.memoryBytes == 200)

    let b = try? #require(usages.first { $0.pid == 2 })
    #expect(b?.cpuUsage == 0)
    #expect(b?.diskReadBytesPerSecond == 0)
}

@Test("进程列表按 CPU/内存/磁盘/名称排序，并可搜索名称与 pid")
func processListFilterSortsAndSearches() {
    let usages = [
        SystemProcessResourceUsage(pid: 10, name: "Chrome", cpuUsage: 0.2, memoryBytes: 900, diskReadBytesPerSecond: 0, diskWrittenBytesPerSecond: 0),
        SystemProcessResourceUsage(pid: 20, name: "Xcode", cpuUsage: 1.5, memoryBytes: 100, diskReadBytesPerSecond: 0, diskWrittenBytesPerSecond: 0),
        SystemProcessResourceUsage(pid: 30, name: "Music", cpuUsage: 0.05, memoryBytes: 500, diskReadBytesPerSecond: 300, diskWrittenBytesPerSecond: 300)
    ]

    var query = SystemProcessListQuery()
    #expect(SystemProcessListFilter.apply(usages, query: query).map(\.name) == ["Xcode", "Chrome", "Music"])

    query.sort = .memory
    #expect(SystemProcessListFilter.apply(usages, query: query).map(\.name) == ["Chrome", "Music", "Xcode"])

    query.sort = .disk
    #expect(SystemProcessListFilter.apply(usages, query: query).map(\.name) == ["Music", "Chrome", "Xcode"])

    query.sort = .name
    #expect(SystemProcessListFilter.apply(usages, query: query).map(\.name) == ["Chrome", "Music", "Xcode"])

    query = SystemProcessListQuery()
    query.searchText = "  chro "
    #expect(SystemProcessListFilter.apply(usages, query: query).map(\.name) == ["Chrome"])

    query.searchText = "20"
    #expect(SystemProcessListFilter.apply(usages, query: query).map(\.name) == ["Xcode"])

    query.searchText = ""
    query.limit = 2
    #expect(SystemProcessListFilter.apply(usages, query: query).count == 2)
}

@Test("进程服务首帧只建基线，结束后清空列表")
@MainActor
func processServiceMonitoringLifecycle() {
    let provider = SequencedProcessProvider()
    let service = SystemProcessResourceService(provider: provider)

    #expect(!service.isMonitoring)
    service.refresh(now: 100)
    // 首帧没有上一次读数：不产出占用
    #expect(service.usages.isEmpty)

    provider.samples = [processSample(pid: 1, name: "A", cpuNanoseconds: 500_000_000, memoryBytes: 10)]
    service.refresh(now: 101)
    #expect(service.usages.count == 1)
    #expect(abs((service.usages.first?.cpuUsage ?? 0) - 0.5) < 0.001)

    service.beginMonitoring(interval: 60)
    #expect(service.isMonitoring)
    service.endMonitoring()
    #expect(!service.isMonitoring)
    #expect(service.usages.isEmpty)
}

private final class SequencedProcessProvider: SystemProcessResourceProviding, @unchecked Sendable {
    var samples: [SystemProcessResourceSample] = [processSample(pid: 1, name: "A", cpuNanoseconds: 0, memoryBytes: 10)]
    func read() -> [SystemProcessResourceSample] { samples }
}

@Test("真实数据源能读到自己进程的占用")
func defaultProcessProviderReadsSelf() {
    let samples = DefaultSystemProcessResourceProvider().read()

    #expect(!samples.isEmpty)
    let selfSample = samples.first { $0.pid == getpid() }
    #expect(selfSample != nil)
    #expect((selfSample?.memoryBytes ?? 0) > 0)
}

@Test("资源设置页有两个一级页且各有文案与图标")
func resourceSettingsPagesCoverTasks() {
    #expect(SystemResourceSettingsPage.allCases == [.overview, .processes])
    for page in SystemResourceSettingsPage.allCases {
        #expect(!page.titleKey.isEmpty)
        #expect(!page.symbol.isEmpty)
        #expect(page.id == page)
    }
    #expect(Set(SystemResourceSettingsPage.allCases.map(\.titleKey)).count == 2)
}
