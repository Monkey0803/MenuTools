import Darwin
import Foundation
import Observation

/// CPU 计数器快照；CPU 使用率由相邻两次快照的差值计算。
struct SystemResourceCPUTicks: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
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
}

enum SystemMemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical
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
        } else {
            cpuUsage = 0
            downloadRate = 0
            uploadRate = 0
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
            networkUploadBytesPerSecond: uploadRate
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

protocol SystemResourceProviding: Sendable {
    func read() -> SystemResourceReading
}

struct DefaultSystemResourceProvider: SystemResourceProviding {
    func read() -> SystemResourceReading {
        let memory = memoryReading()
        let disk = diskReading()
        let network = networkReading()
        return SystemResourceReading(
            timestamp: ProcessInfo.processInfo.systemUptime,
            cpuTicks: cpuReading(),
            memoryUsedBytes: memory.used,
            memoryTotalBytes: memory.total,
            diskAvailableBytes: disk.available,
            diskTotalBytes: disk.total,
            networkReceivedBytes: network.received,
            networkSentBytes: network.sent
        )
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

/// 负责定时采样并向 SwiftUI 提供最新资源快照。
@MainActor
@Observable
final class SystemResourceService {
    private let provider: any SystemResourceProviding
    private var previousReading: SystemResourceReading?

    private(set) var snapshot: SystemResourceSnapshot?

    init(provider: any SystemResourceProviding = DefaultSystemResourceProvider()) {
        self.provider = provider
    }

    func refresh() {
        let current = provider.read()
        snapshot = SystemResourceCalculator.snapshot(
            current: current,
            previous: previousReading
        )
        previousReading = current
    }
}
