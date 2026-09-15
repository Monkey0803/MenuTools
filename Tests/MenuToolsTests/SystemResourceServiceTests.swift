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

@Test("资源设置页有概览、进程、历史三个一级页且各有文案与图标")
func resourceSettingsPagesCoverTasks() {
    #expect(SystemResourceSettingsPage.allCases == [.overview, .processes, .history])
    for page in SystemResourceSettingsPage.allCases {
        #expect(!page.titleKey.isEmpty)
        #expect(!page.symbol.isEmpty)
        #expect(page.id == page)
    }
    #expect(Set(SystemResourceSettingsPage.allCases.map(\.titleKey)).count == 3)
}

@Test("历史聚合在同一分钟内取平均，并对齐到分钟")
func historyAggregatorAveragesWithinMinute() {
    let bucketDate = SystemResourceHistoryAggregator.bucketTimestamp(for: Date(timeIntervalSince1970: 1_800_000_030))
    #expect(bucketDate.timeIntervalSince1970 == 1_800_000_000)

    var bucket = SystemResourceHistoryAggregator.merging(
        existing: nil,
        snapshot: historySnapshot(cpu: 0.2, memory: 100, read: 1_000, write: 100),
        timestamp: bucketDate
    )
    #expect(bucket.sampleCount == 1)
    #expect(bucket.cpuUsage == 0.2)

    bucket = SystemResourceHistoryAggregator.merging(
        existing: bucket,
        snapshot: historySnapshot(cpu: 0.6, memory: 300, read: 3_000, write: 300),
        timestamp: bucketDate
    )
    #expect(bucket.sampleCount == 2)
    #expect(abs(bucket.cpuUsage - 0.4) < 0.001)
    #expect(bucket.diskReadBytesPerSecond == 2_000)
    // 内存取最后一次读到的值
    #expect(bucket.memoryUsedBytes == 300)
    #expect(abs(bucket.memoryUsage - 0.3) < 0.001)
}

@Test("历史超过保留期会被丢掉")
func historyAggregatorPrunesOldBuckets() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fresh = SystemResourceHistoryAggregator.merging(
        existing: nil,
        snapshot: historySnapshot(cpu: 0.1),
        timestamp: now.addingTimeInterval(-60)
    )
    let stale = SystemResourceHistoryAggregator.merging(
        existing: nil,
        snapshot: historySnapshot(cpu: 0.1),
        timestamp: now.addingTimeInterval(-SystemResourceHistoryAggregator.retentionInterval - 60)
    )

    let pruned = SystemResourceHistoryAggregator.pruned([fresh, stale], now: now)

    #expect(pruned.count == 1)
    #expect(pruned.first?.timestamp == fresh.timestamp)
}

@Test("资源历史库可写入、读取、覆盖同一分钟并清空")
func resourceHistoryStoreRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MenuToolsResourceHistory-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("history.sqlite3")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = SystemResourceHistoryStore(fileURL: fileURL)
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let first = SystemResourceHistoryAggregator.merging(
        existing: nil,
        snapshot: historySnapshot(cpu: 0.25, memory: 200, read: 500, write: 50),
        timestamp: base
    )
    store.save([first])

    let loaded = store.load(since: base.addingTimeInterval(-60))
    #expect(loaded.count == 1)
    #expect(abs((loaded.first?.cpuUsage ?? 0) - 0.25) < 0.001)

    // 同一分钟再写：覆盖而不是新增
    let merged = SystemResourceHistoryAggregator.merging(
        existing: first,
        snapshot: historySnapshot(cpu: 0.75, memory: 400, read: 1_500, write: 150),
        timestamp: base
    )
    store.save([merged])
    let reloaded = store.load(since: base.addingTimeInterval(-60))
    #expect(reloaded.count == 1)
    #expect(abs((reloaded.first?.cpuUsage ?? 0) - 0.5) < 0.001)
    #expect(reloaded.first?.sampleCount == 2)

    // 时间范围过滤
    #expect(store.load(since: base.addingTimeInterval(60)).isEmpty)
    #expect(store.storageUsage().totalBytes > 0)

    store.clearAll()
    #expect(store.load(since: base.addingTimeInterval(-60)).isEmpty)
}

@Test("资源服务按分钟聚合历史，分钟切换才写库，停止时冲刷")
@MainActor
func resourceServiceRecordsHistoryPerMinute() {
    let provider = CountingResourceProvider()
    let store = RecordingHistoryStore()
    let service = SystemResourceService(
        provider: provider,
        memoryReleaser: NoopMemoryReleaser(),
        historyStore: store
    )
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    service.refresh(now: base)
    service.refresh(now: base.addingTimeInterval(2))
    // 同一分钟：两次采样合并成一条，且还没有写库
    #expect(service.historyBuckets.count == 1)
    #expect(service.historyBuckets.first?.sampleCount == 2)
    #expect(store.savedBatches.isEmpty)

    // 进入下一分钟：上一分钟落库，新桶开始
    service.refresh(now: base.addingTimeInterval(60))
    #expect(store.savedBatches.count == 1)
    #expect(store.savedBatches.first?.first?.sampleCount == 2)

    service.refresh(now: base.addingTimeInterval(120))
    service.endMonitoring()
    // 结束时冲刷并停止
    #expect(!service.isMonitoring)
    #expect(store.savedBatches.count >= 2)

    service.clearHistory()
    #expect(service.historyBuckets.isEmpty)
    #expect(store.didClearAll)
}

private final class RecordingHistoryStore: SystemResourceHistoryStoring, @unchecked Sendable {
    var savedBatches: [[SystemResourceHistoryBucket]] = []
    var didClearAll = false
    var stored: [SystemResourceHistoryBucket] = []

    func load(since: Date) -> [SystemResourceHistoryBucket] {
        stored.filter { $0.timestamp >= since }
    }

    func save(_ buckets: [SystemResourceHistoryBucket]) {
        savedBatches.append(buckets)
        stored.append(contentsOf: buckets)
    }

    func clearAll() {
        didClearAll = true
        stored = []
    }

    func storageUsage() -> SystemResourceHistoryStorageUsage {
        SystemResourceHistoryStorageUsage(databaseBytes: 0, walBytes: 0, sharedMemoryBytes: 0)
    }
}

private func historySnapshot(
    cpu: Double,
    memory: Int64 = 0,
    total: Int64 = 1_000,
    read: Int64 = 0,
    write: Int64 = 0
) -> SystemResourceSnapshot {
    SystemResourceSnapshot(
        cpuUsage: cpu,
        memoryUsedBytes: memory,
        memoryTotalBytes: total,
        memoryPressure: .normal,
        diskAvailableBytes: 0,
        diskTotalBytes: 0,
        networkDownloadBytesPerSecond: 0,
        networkUploadBytesPerSecond: 0,
        diskReadBytesPerSecond: read,
        diskWriteBytesPerSecond: write
    )
}

@Test("CPU 需持续高于阈值才告警，掉回阈值以下会重置计时")
func alertPolicyRequiresSustainedCPU() {
    var policy = SystemResourceAlertPolicy()
    let thresholds = SystemResourceAlertThresholds(cpuUsage: 0.9, cpuSustainDuration: 300, diskFreeRatio: 0.1)
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    // 未达阈值不告警
    #expect(policy.evaluate(snapshot: alertSnapshot(cpu: 0.5), now: base, thresholds: thresholds).isEmpty)

    // 达到阈值但时长不够
    #expect(policy.evaluate(snapshot: alertSnapshot(cpu: 0.95), now: base, thresholds: thresholds).isEmpty)
    #expect(policy.evaluate(snapshot: alertSnapshot(cpu: 0.95), now: base.addingTimeInterval(200), thresholds: thresholds).isEmpty)

    // 坚持满 5 分钟 → 告警一次
    #expect(policy.evaluate(snapshot: alertSnapshot(cpu: 0.95), now: base.addingTimeInterval(320), thresholds: thresholds) == [.cpuSustained])
    // 冷却期内不再告警
    #expect(policy.evaluate(snapshot: alertSnapshot(cpu: 0.97), now: base.addingTimeInterval(400), thresholds: thresholds).isEmpty)
    // 冷却结束且仍在高位 → 再次告警
    #expect(policy.evaluate(snapshot: alertSnapshot(cpu: 0.97), now: base.addingTimeInterval(320 + 1_900), thresholds: thresholds) == [.cpuSustained])

    // 中途掉回阈值以下：计时重置，需要重新坚持 5 分钟
    var reset = SystemResourceAlertPolicy()
    _ = reset.evaluate(snapshot: alertSnapshot(cpu: 0.95), now: base, thresholds: thresholds)
    _ = reset.evaluate(snapshot: alertSnapshot(cpu: 0.2), now: base.addingTimeInterval(120), thresholds: thresholds)
    #expect(reset.evaluate(snapshot: alertSnapshot(cpu: 0.95), now: base.addingTimeInterval(400), thresholds: thresholds).isEmpty)
    #expect(reset.evaluate(snapshot: alertSnapshot(cpu: 0.95), now: base.addingTimeInterval(720), thresholds: thresholds) == [.cpuSustained])
}

@Test("内存只在临界时告警，磁盘按剩余比例告警，各自有冷却")
func alertPolicyCoversMemoryAndDisk() {
    var policy = SystemResourceAlertPolicy()
    let thresholds = SystemResourceAlertThresholds(cpuUsage: 0.99, cpuSustainDuration: 300, diskFreeRatio: 0.1)
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    // 内存偏高但不临界 → 不告警
    #expect(policy.evaluate(snapshot: alertSnapshot(memoryPressure: .warning), now: base, thresholds: thresholds).isEmpty)
    #expect(policy.evaluate(snapshot: alertSnapshot(memoryPressure: .critical), now: base, thresholds: thresholds) == [.memoryPressure])
    // 冷却内不重复
    #expect(policy.evaluate(snapshot: alertSnapshot(memoryPressure: .critical), now: base.addingTimeInterval(60), thresholds: thresholds).isEmpty)

    // 磁盘剩余 5%（阈值 10%）→ 告警；冷却内不重复
    var diskPolicy = SystemResourceAlertPolicy()
    #expect(diskPolicy.evaluate(
        snapshot: alertSnapshot(diskFree: 50, diskTotal: 1_000),
        now: base,
        thresholds: thresholds
    ) == [.diskSpace])
    #expect(diskPolicy.evaluate(
        snapshot: alertSnapshot(diskFree: 50, diskTotal: 1_000),
        now: base.addingTimeInterval(3_600),
        thresholds: thresholds
    ).isEmpty)

    // 剩余 50% 远高于阈值 → 不告警（阈值收紧到 1% 也不该误报）
    var healthyPolicy = SystemResourceAlertPolicy()
    #expect(healthyPolicy.evaluate(
        snapshot: alertSnapshot(diskFree: 500, diskTotal: 1_000),
        now: base,
        thresholds: SystemResourceAlertThresholds(cpuUsage: 0.9, cpuSustainDuration: 300, diskFreeRatio: 0.01)
    ).isEmpty)
    #expect(healthyPolicy.evaluate(
        snapshot: alertSnapshot(diskFree: 500, diskTotal: 1_000),
        now: base,
        thresholds: thresholds
    ).isEmpty)

    // 磁盘容量未知（0）时不误报
    var unknownDisk = SystemResourceAlertPolicy()
    #expect(unknownDisk.evaluate(
        snapshot: alertSnapshot(diskFree: 0, diskTotal: 0),
        now: base,
        thresholds: thresholds
    ).isEmpty)
}

@Test("阈值会归一化到有效范围")
func alertThresholdsNormalize() {
    let normalized = SystemResourceAlertThresholds(cpuUsage: 5, cpuSustainDuration: 1, diskFreeRatio: -1).normalized()

    #expect(normalized.cpuUsage == 1)
    #expect(normalized.cpuSustainDuration == 30)
    #expect(normalized.diskFreeRatio == 0.01)
}

@Test("通知授权状态映射覆盖未决定、拒绝与已授权")
func resourceNotificationPermissionMapping() {
    #expect(SystemResourceNotificationPermission.resolve(.notDetermined) == .notRequested)
    #expect(SystemResourceNotificationPermission.resolve(.denied) == .denied)
    #expect(SystemResourceNotificationPermission.resolve(.authorized) == .authorized)
    #expect(SystemResourceNotificationPermission.resolve(.provisional) == .authorized)
}

private func alertSnapshot(
    cpu: Double = 0.1,
    memoryPressure: SystemMemoryPressure = .normal,
    diskFree: Int64 = 1_000,
    diskTotal: Int64 = 1_000
) -> SystemResourceSnapshot {
    SystemResourceSnapshot(
        cpuUsage: cpu,
        memoryUsedBytes: 0,
        memoryTotalBytes: 0,
        memoryPressure: memoryPressure,
        diskAvailableBytes: diskFree,
        diskTotalBytes: diskTotal,
        networkDownloadBytesPerSecond: 0,
        networkUploadBytesPerSecond: 0
    )
}

@Test("服务按阈值触发告警并遵守开关与冷却")
@MainActor
func resourceServiceFiresAlerts() {
    let defaults = UserDefaults(suiteName: "SystemResourceAlertTests.\(UUID().uuidString)") ?? .standard
    defaults.removePersistentDomain(forName: defaults.description)
    let alerter = RecordingResourceAlerter()
    let service = SystemResourceService(
        provider: AlertingResourceProvider(),
        memoryReleaser: NoopMemoryReleaser(),
        historyStore: RecordingHistoryStore(),
        alerter: alerter,
        userDefaults: defaults
    )
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    service.setAlertThresholds(SystemResourceAlertThresholds(cpuUsage: 0.9, cpuSustainDuration: 300, diskFreeRatio: 0.1))

    // 首次采样只建立基线，CPU 使用率为 0，不告警
    service.refresh(now: base)
    #expect(alerter.sent.isEmpty)

    // 第二次采样起进入高位，但持续时长还不够
    service.refresh(now: base.addingTimeInterval(10))
    #expect(alerter.sent.isEmpty)

    // 高位持续超过 5 分钟 → 触发一次 CPU 告警
    service.refresh(now: base.addingTimeInterval(330))
    #expect(alerter.sent == [.cpuSustained])

    // 冷却期内不再触发
    service.refresh(now: base.addingTimeInterval(400))
    #expect(alerter.sent == [.cpuSustained])

    // 关闭告警后不再发送
    service.setAlertsEnabled(false)
    service.refresh(now: base.addingTimeInterval(330 + 1_900))
    #expect(alerter.sent == [.cpuSustained])
    #expect(!service.alertsEnabled)
}

@Test("阈值会持久化并在新实例里恢复")
@MainActor
func resourceAlertThresholdsPersist() {
    let suiteName = "SystemResourceAlertThresholdTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)

    let service = SystemResourceService(
        provider: CountingResourceProvider(),
        memoryReleaser: NoopMemoryReleaser(),
        historyStore: RecordingHistoryStore(),
        alerter: RecordingResourceAlerter(),
        userDefaults: defaults
    )
    service.setAlertsEnabled(false)
    service.setAlertThresholds(SystemResourceAlertThresholds(cpuUsage: 0.5, cpuSustainDuration: 60, diskFreeRatio: 0.3))

    let restored = SystemResourceService(
        provider: CountingResourceProvider(),
        memoryReleaser: NoopMemoryReleaser(),
        historyStore: RecordingHistoryStore(),
        alerter: RecordingResourceAlerter(),
        userDefaults: defaults
    )
    #expect(!restored.alertsEnabled)
    #expect(restored.alertThresholds.cpuUsage == 0.5)
    #expect(restored.alertThresholds.cpuSustainDuration == 60)
    #expect(restored.alertThresholds.diskFreeRatio == 0.3)
}

@MainActor
private final class RecordingResourceAlerter: SystemResourceAlerting {
    var sent: [SystemResourceAlertKind] = []
    var requestedPermission = false
    var permission: SystemResourceNotificationPermission = .authorized

    func requestPermission() { requestedPermission = true }
    func currentPermission() async -> SystemResourceNotificationPermission { permission }
    func send(_ kind: SystemResourceAlertKind, snapshot: SystemResourceSnapshot) { sent.append(kind) }
}

/// 持续高 CPU 的数据源，用来驱动告警（计数器必须递增，否则差值为 0）。
private final class AlertingResourceProvider: SystemResourceProviding, @unchecked Sendable {
    private var user: UInt64 = 0
    private var idle: UInt64 = 0

    func read() -> SystemResourceReading {
        user += 95
        idle += 5
        return SystemResourceReading(
            timestamp: 0,
            cpuTicks: SystemResourceCPUTicks(user: user, system: 0, idle: idle, nice: 0),
            memoryUsedBytes: 1,
            memoryTotalBytes: 2,
            diskAvailableBytes: 500,
            diskTotalBytes: 1_000,
            networkReceivedBytes: 0,
            networkSentBytes: 0
        )
    }
}

@Test("历史按范围聚合：桶内取平均、内存取最后一个、范围外丢弃")
func historyAggregatesByRange() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func bucket(offset: TimeInterval, cpu: Double, memory: Int64, read: Int64) -> SystemResourceHistoryBucket {
        SystemResourceHistoryBucket(
            timestamp: base.addingTimeInterval(offset),
            cpuUsage: cpu,
            memoryUsedBytes: memory,
            memoryTotalBytes: 1_000,
            diskReadBytesPerSecond: read,
            diskWriteBytesPerSecond: 0,
            sampleCount: 1
        )
    }
    let buckets = [
        bucket(offset: 0, cpu: 0.2, memory: 100, read: 100),
        bucket(offset: 60, cpu: 0.4, memory: 200, read: 300),
        bucket(offset: 300, cpu: 0.8, memory: 300, read: 500),
        bucket(offset: 3_600, cpu: 0.9, memory: 400, read: 700)
    ]

    // 5 分钟一个桶：前两个合并，第三个单独，第四个超出 since
    let aggregated = SystemResourceHistoryAggregator.aggregated(
        buckets,
        interval: 300,
        since: base.addingTimeInterval(-1)
    )

    #expect(aggregated.count == 3)
    #expect(abs(aggregated[0].cpuUsage - 0.3) < 0.001)
    #expect(aggregated[0].memoryUsedBytes == 200)   // 取桶内最后一个
    #expect(aggregated[0].diskReadBytesPerSecond == 200)
    #expect(aggregated[0].sampleCount == 2)
    #expect(abs(aggregated[1].cpuUsage - 0.8) < 0.001)

    // since 之后只剩最后一个
    let recent = SystemResourceHistoryAggregator.aggregated(
        buckets,
        interval: 300,
        since: base.addingTimeInterval(3_000)
    )
    #expect(recent.count == 1)
    #expect(recent[0].memoryUsedBytes == 400)
}

@Test("范围决定覆盖时长与桶间隔，图表布局能命中悬停柱子")
func historyRangeAndChartLayout() {
    #expect(SystemResourceHistoryRange.allCases == [.hour, .day, .week, .month])
    #expect(SystemResourceHistoryRange.hour.duration == 3_600)
    #expect(SystemResourceHistoryRange.month.duration == 30 * 24 * 60 * 60)
    // 桶数量控制在可绘制范围
    for range in SystemResourceHistoryRange.allCases {
        let count = range.duration / range.bucketInterval
        #expect(count <= 300)
        #expect(count >= 24)
        #expect(!range.titleKey.isEmpty)
    }

    // 悬停命中：宽度 300、10 个柱子 → 每个 30pt
    #expect(SystemResourceHistoryChartLayout.hoveredIndex(x: 0, width: 300, count: 10) == 0)
    #expect(SystemResourceHistoryChartLayout.hoveredIndex(x: 45, width: 300, count: 10) == 1)
    #expect(SystemResourceHistoryChartLayout.hoveredIndex(x: 299, width: 300, count: 10) == 9)
    #expect(SystemResourceHistoryChartLayout.hoveredIndex(x: 300, width: 300, count: 10) == 9)
    #expect(SystemResourceHistoryChartLayout.hoveredIndex(x: -1, width: 300, count: 10) == nil)
    #expect(SystemResourceHistoryChartLayout.hoveredIndex(x: 10, width: 300, count: 0) == nil)
    #expect(SystemResourceHistoryChartLayout.barWidth(width: 300, count: 10) > 1)
}

@Test("采样档位：面板 2 秒、后台 10 秒、面板关闭回落、都关则停并清快照")
@MainActor
func resourceSamplingTiers() {
    let service = SystemResourceService(
        provider: CountingResourceProvider(),
        memoryReleaser: NoopMemoryReleaser(),
        historyStore: RecordingHistoryStore(),
        alerter: RecordingResourceAlerter(),
        userDefaults: UserDefaults(suiteName: "SystemResourceTierTests.\(UUID().uuidString)") ?? .standard
    )

    // 未启用任何采样源
    #expect(!service.isMonitoring)
    #expect(service.currentSamplingInterval == nil)

    // 插件启用（后台档）
    service.setBackgroundMonitoring(true)
    #expect(service.isMonitoring)
    #expect(service.currentSamplingInterval == SystemResourceSamplingPolicy.alertInterval)

    // 面板打开 → 升到面板档
    service.beginMonitoring()
    #expect(service.currentSamplingInterval == SystemResourceSamplingPolicy.panelInterval)

    // 面板关闭 → 回落到后台档，仍在采样
    service.endPanelMonitoring()
    #expect(service.isMonitoring)
    #expect(service.currentSamplingInterval == SystemResourceSamplingPolicy.alertInterval)

    // 后台需求消失 → 完全停止并清快照
    service.setBackgroundMonitoring(false)
    #expect(!service.isMonitoring)
    #expect(service.currentSamplingInterval == nil)
    #expect(service.snapshot == nil)

    // 插件关闭路径同样彻底停止
    service.beginMonitoring()
    service.endMonitoring()
    #expect(!service.isMonitoring)
    #expect(service.snapshot == nil)
}

@Test("菜单栏选择资源指标或开启告警时会开启后台采样")
@MainActor
func resourceBackgroundSamplingFollowsSettings() {
    let suiteName = "SystemResourceBackgroundTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    let service = SystemResourceService(
        provider: CountingResourceProvider(),
        memoryReleaser: NoopMemoryReleaser(),
        historyStore: RecordingHistoryStore(),
        alerter: RecordingResourceAlerter(),
        userDefaults: defaults
    )

    // 默认：告警开启（默认 true）→ 需要后台采样
    service.refreshBackgroundSampling(userDefaults: defaults)
    #expect(service.isMonitoring)

    // 关掉告警且菜单栏不显示资源指标 → 停
    service.setAlertsEnabled(false)
    #expect(!service.isMonitoring)

    // 菜单栏选 CPU → 重新开启后台采样
    defaults.set(MenuBarMetric.cpu.rawValue, forKey: SettingsKey.menuBarMetric)
    service.refreshBackgroundSampling(userDefaults: defaults)
    #expect(service.isMonitoring)
    #expect(service.currentSamplingInterval == SystemResourceSamplingPolicy.alertInterval)

    // 切回自动（不显示资源指标）且告警仍关 → 又停
    defaults.set(MenuBarMetric.automatic.rawValue, forKey: SettingsKey.menuBarMetric)
    service.refreshBackgroundSampling(userDefaults: defaults)
    #expect(!service.isMonitoring)
}

@Test("统一菜单栏选择器：指定项优先，自动时沿用网速优先其次音量")
func menuBarMetricResolverPicksSingleSource() {
    // 未设置或自动 → 旧行为
    #expect(MenuBarMetricResolver.resolve(unified: nil, trafficModeOff: false, volumeModeOff: false) == .networkSpeed)
    #expect(MenuBarMetricResolver.resolve(unified: .automatic, trafficModeOff: false, volumeModeOff: false) == .networkSpeed)
    #expect(MenuBarMetricResolver.resolve(unified: .automatic, trafficModeOff: true, volumeModeOff: false) == .volume)
    #expect(MenuBarMetricResolver.resolve(unified: .automatic, trafficModeOff: true, volumeModeOff: true) == .off)

    // 指定项覆盖模块设置，且互斥（只可能返回一个）
    for metric in [MenuBarMetric.cpu, .memory, .disk, .volume, .networkSpeed, .off] {
        #expect(MenuBarMetricResolver.resolve(unified: metric, trafficModeOff: false, volumeModeOff: false) == metric)
        #expect(MenuBarMetricResolver.resolve(unified: metric, trafficModeOff: true, volumeModeOff: true) == metric)
    }
}

@Test("资源菜单栏标题：只对 CPU/内存/磁盘产出，百分比固定三位宽")
func resourceMenuBarPresenterFormatsTitle() {
    let snapshot = SystemResourceSnapshot(
        cpuUsage: 0.42,
        memoryUsedBytes: 680,
        memoryTotalBytes: 1_000,
        memoryPressure: .normal,
        diskAvailableBytes: 120,
        diskTotalBytes: 1_000,
        networkDownloadBytesPerSecond: 0,
        networkUploadBytesPerSecond: 0
    )

    let cpuTitle = SystemResourceMenuBarPresenter.title(snapshot: snapshot, metric: .cpu)
    #expect(cpuTitle?.hasSuffix(" 42%") == true)
    let memoryTitle = SystemResourceMenuBarPresenter.title(snapshot: snapshot, metric: .memory)
    #expect(memoryTitle?.hasSuffix(" 68%") == true)
    // 磁盘显示已用占比：1 - 120/1000 = 88%
    let diskTitle = SystemResourceMenuBarPresenter.title(snapshot: snapshot, metric: .disk)
    #expect(diskTitle?.hasSuffix(" 88%") == true)

    // 固定宽度：个位数百分比也占三位
    #expect(SystemResourceMenuBarPresenter.percent(0.05) == "  5%")
    #expect(SystemResourceMenuBarPresenter.percent(1) == "100%")
    #expect(SystemResourceMenuBarPresenter.percent(0) == "  0%")
    // 越界与 NaN 收敛
    #expect(SystemResourceMenuBarPresenter.percent(-1) == "  0%")
    #expect(SystemResourceMenuBarPresenter.percent(.nan) == "  0%")

    // 其余取值不产出标题；没有快照也不产出
    for metric in [MenuBarMetric.automatic, .networkSpeed, .volume, .off] {
        #expect(SystemResourceMenuBarPresenter.title(snapshot: snapshot, metric: metric) == nil)
    }
    #expect(SystemResourceMenuBarPresenter.title(snapshot: nil, metric: .cpu) == nil)

    // 每个取值都有文案，且自动档带说明
    for metric in MenuBarMetric.allCases {
        #expect(!metric.titleKey.isEmpty)
    }
    #expect(MenuBarMetric.automatic.footerKey != nil)
    #expect(MenuBarMetric.cpu.footerKey == nil)
}

@Test("资源自检逐步给出结论：数据源齐全时全绿")
func selfCheckReportsHealthySources() {
    let snapshot = SystemResourceSnapshot(
        cpuUsage: 0.25,
        memoryUsedBytes: 400,
        memoryTotalBytes: 1_000,
        memoryPressure: .normal,
        diskAvailableBytes: 500,
        diskTotalBytes: 1_000,
        networkDownloadBytesPerSecond: 0,
        networkUploadBytesPerSecond: 0,
        coreUsages: [SystemResourceCoreUsage(index: 0, usage: 0.2), SystemResourceCoreUsage(index: 1, usage: 0.3)]
    )

    let steps = SystemResourceSelfCheck.steps(
        snapshot: snapshot,
        isMonitoring: true,
        samplingInterval: 2,
        processCount: 42,
        historyCount: 12,
        historyStorageBytes: 4_096,
        alertsEnabled: true,
        notificationPermission: .authorized
    )

    #expect(steps.count == 7)
    #expect(steps.map(\.id) == ["cpu", "disk", "process", "history", "sampling", "notification", "optional"])
    #expect(steps.allSatisfy { $0.status == .ok })
    #expect(steps.allSatisfy { $0.adviceKey == nil })
    // 测试进程里 L() 返回原始键，所以这里只断言核心数与百分比这两项与语言无关的信息
    #expect(steps[0].detail?.contains("2") == true)
    #expect(steps[0].detail?.contains("25%") == true)
    #expect(steps[4].detail == "2s")
}

@Test("资源自检能指出取数失败、无历史、未采样与通知被拒")
func selfCheckReportsProblems() {
    let steps = SystemResourceSelfCheck.steps(
        snapshot: nil,
        isMonitoring: false,
        samplingInterval: nil,
        processCount: 0,
        historyCount: 0,
        historyStorageBytes: 0,
        alertsEnabled: true,
        notificationPermission: .denied
    )

    #expect(steps.count == 7)
    #expect(steps[0].status == .failed && steps[0].adviceKey != nil)   // CPU/内存取不到
    #expect(steps[1].status == .failed && steps[1].adviceKey != nil)   // 磁盘取不到
    #expect(steps[2].status == .warning)                               // 进程列表为空
    #expect(steps[3].status == .warning)                               // 还没有历史
    #expect(steps[4].status == .warning)                               // 未采样
    #expect(steps[5].status == .failed)                                // 通知被系统拒绝

    // 只有单核数据源时给警告而不是失败
    let singleCore = SystemResourceSelfCheck.steps(
        snapshot: SystemResourceSnapshot(
            cpuUsage: 0.1,
            memoryUsedBytes: 1,
            memoryTotalBytes: 2,
            memoryPressure: .normal,
            diskAvailableBytes: 1,
            diskTotalBytes: 2,
            networkDownloadBytesPerSecond: 0,
            networkUploadBytesPerSecond: 0,
            coreUsages: []
        ),
        isMonitoring: true,
        samplingInterval: 10,
        processCount: 1,
        historyCount: 1,
        historyStorageBytes: 1,
        alertsEnabled: false,
        notificationPermission: .notRequested
    )
    #expect(singleCore[0].status == .warning)
    // 未开启告警时授权状态不参与判定
    #expect(singleCore[5].status == .ok)

    // 未请求授权（开着告警）→ 警告
    let pending = SystemResourceSelfCheck.steps(
        snapshot: nil, isMonitoring: false, samplingInterval: nil, processCount: 0,
        historyCount: 0, historyStorageBytes: 0,
        alertsEnabled: true, notificationPermission: .notRequested
    )
    #expect(pending[5].status == .warning)
}

@Test("自检状态有文案与图标")
func selfCheckStatusHasPresentation() {
    for status in [SystemResourceSelfCheckStatus.ok, .warning, .failed] {
        #expect(!status.titleKey.isEmpty)
        #expect(!status.symbol.isEmpty)
    }
}

@Test("GPU 占用解析：支持数字/字符串，越界与缺失返回 nil")
func gpuStatisticsParserHandlesValues() {
    #expect(SystemResourceGPUStatisticsParser.utilization(from: ["Device Utilization %": 15]) == 0.15)
    #expect(SystemResourceGPUStatisticsParser.utilization(from: ["Device Utilization %": 0]) == 0)
    #expect(SystemResourceGPUStatisticsParser.utilization(from: ["Device Utilization %": 100]) == 1)
    #expect(SystemResourceGPUStatisticsParser.utilization(from: ["Device Utilization %": "42"]) == 0.42)
    #expect(SystemResourceGPUStatisticsParser.utilization(from: ["Device Utilization %": NSNumber(value: 7.5)]) == 0.075)

    // 缺失键、非数值、越界（负数/超大）都视为不可用
    #expect(SystemResourceGPUStatisticsParser.utilization(from: [:]) == nil)
    #expect(SystemResourceGPUStatisticsParser.utilization(from: ["Device Utilization %": "abc"]) == nil)
    #expect(SystemResourceGPUStatisticsParser.utilization(from: ["Device Utilization %": -5]) == nil)
    #expect(SystemResourceGPUStatisticsParser.utilization(from: ["Device Utilization %": 10_000]) == nil)
    #expect(SystemResourceGPUStatisticsParser.utilization(from: ["Device Utilization %": [1, 2]]) == nil)
    // 超过 100% 但在合理上限内会被收敛到 1（多 GPU 叠加场景）
    #expect(SystemResourceGPUStatisticsParser.utilization(from: ["Device Utilization %": 150]) == 1)
}

@Test("SMC sp78 温度解码：正值、负值与不合理读数")
func smcTemperatureDecoderHandlesSP78() {
    // 0x3000 = 12288 / 256 = 48.0
    #expect(SystemResourceSMCDecoder.temperature(sp78: 0x30, 0x00) == 48)
    // 0x2D80 = 11648 / 256 = 45.5
    #expect(SystemResourceSMCDecoder.temperature(sp78: 0x2D, 0x80) == 45.5)
    // 0xFF80 = -128 / 256 = -0.5
    #expect(SystemResourceSMCDecoder.temperature(sp78: 0xFF, 0x80) == -0.5)
    // 0x8000 = -128 摄氏度：明显不合理，判为无效
    #expect(SystemResourceSMCDecoder.temperature(sp78: 0x80, 0x00) == nil)
    // 0x7FFF = 127.99：仍在可接受范围内
    #expect(SystemResourceSMCDecoder.temperature(sp78: 0x7F, 0xFF) != nil)
}

@Test("可选指标会随快照透出，缺失时保持 nil")
func snapshotCarriesOptionalMetrics() {
    func reading(gpu: Double?, temperature: Double?) -> SystemResourceReading {
        SystemResourceReading(
            timestamp: 0,
            cpuTicks: SystemResourceCPUTicks(user: 1, system: 0, idle: 1, nice: 0),
            memoryUsedBytes: 1,
            memoryTotalBytes: 2,
            diskAvailableBytes: 1,
            diskTotalBytes: 2,
            networkReceivedBytes: 0,
            networkSentBytes: 0,
            gpuUsage: gpu,
            temperatureCelsius: temperature
        )
    }

    let present = SystemResourceCalculator.snapshot(
        current: reading(gpu: 0.15, temperature: 48),
        previous: nil
    )
    #expect(present.gpuUsage == 0.15)
    #expect(present.temperatureCelsius == 48)

    // 越界 GPU 会被收敛
    let clamped = SystemResourceCalculator.snapshot(current: reading(gpu: 2.5, temperature: nil), previous: nil)
    #expect(clamped.gpuUsage == 1)
    #expect(clamped.temperatureCelsius == nil)

    let absent = SystemResourceCalculator.snapshot(current: reading(gpu: nil, temperature: nil), previous: nil)
    #expect(absent.gpuUsage == nil)
    #expect(absent.temperatureCelsius == nil)
}

@Test("真机读取器：GPU 可读则为 0…1，温度不可读时应为 nil 而不是 0")
func optionalMetricsReaderIsHonestOnThisMachine() {
    let reader = DefaultSystemResourceOptionalMetricsReader()
    if let gpu = reader.readGPUUsage() {
        #expect(gpu >= 0 && gpu <= 1)
    }
    // SMC 通道不可用时必须返回 nil（界面据此隐藏），不能伪造 0 度
    if let temperature = reader.readTemperatureCelsius() {
        #expect(temperature > -40 && temperature < 150)
    }
}
