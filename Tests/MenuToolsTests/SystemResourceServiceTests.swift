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
