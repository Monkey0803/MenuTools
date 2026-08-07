import Foundation
import Testing
@testable import MenuTools

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
