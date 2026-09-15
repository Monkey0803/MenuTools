import Darwin
import Foundation
import Observation

/// 单个进程的原始读数（累计值）。
struct SystemProcessResourceSample: Equatable, Sendable, Identifiable {
    let pid: pid_t
    let name: String
    /// 累计 CPU 时间（纳秒）。
    let cpuTimeNanoseconds: UInt64
    /// 物理内存占用（字节，对应活动监视器的「内存」列）。
    let memoryBytes: Int64
    let diskReadBytes: Int64
    let diskWrittenBytes: Int64

    var id: pid_t { pid }
}

/// 展示层使用的进程占用（含速率）。
struct SystemProcessResourceUsage: Equatable, Sendable, Identifiable {
    let pid: pid_t
    let name: String
    /// 相对单核的 CPU 占用：0.5 表示半核，1.5 表示一核半。
    let cpuUsage: Double
    let memoryBytes: Int64
    let diskReadBytesPerSecond: Int64
    let diskWrittenBytesPerSecond: Int64

    var id: pid_t { pid }
}

enum SystemProcessResourceCalculator {
    /// 用相邻两次采样算速率；只输出两次都存在的进程（新进程首帧不虚报）。
    static func usages(
        current: [SystemProcessResourceSample],
        previous: [SystemProcessResourceSample],
        elapsed: TimeInterval
    ) -> [SystemProcessResourceUsage] {
        let safeElapsed = max(elapsed, 0.001)
        var previousByPID: [pid_t: SystemProcessResourceSample] = [:]
        for sample in previous {
            previousByPID[sample.pid] = sample
        }
        return current.compactMap { sample in
            guard let before = previousByPID[sample.pid] else { return nil }
            let cpuDelta = sample.cpuTimeNanoseconds >= before.cpuTimeNanoseconds
                ? sample.cpuTimeNanoseconds - before.cpuTimeNanoseconds
                : 0
            let cpuUsage = min(Double(cpuDelta) / 1_000_000_000 / safeElapsed, Double(ProcessInfo.processInfo.activeProcessorCount))
            return SystemProcessResourceUsage(
                pid: sample.pid,
                name: sample.name,
                cpuUsage: max(cpuUsage, 0),
                memoryBytes: max(sample.memoryBytes, 0),
                diskReadBytesPerSecond: rate(sample.diskReadBytes, before.diskReadBytes, elapsed: safeElapsed),
                diskWrittenBytesPerSecond: rate(sample.diskWrittenBytes, before.diskWrittenBytes, elapsed: safeElapsed)
            )
        }
    }

    private static func rate(_ current: Int64, _ previous: Int64, elapsed: TimeInterval) -> Int64 {
        guard current > previous else { return 0 }
        return Int64(Double(current - previous) / elapsed)
    }
}

/// 进程列表的排序方式。
enum SystemProcessSort: String, CaseIterable, Equatable, Sendable {
    case cpu
    case memory
    case disk
    case name

    var titleKey: String { "resource.process.sort.\(rawValue)" }
}

struct SystemProcessListQuery: Equatable, Sendable {
    var searchText: String = ""
    var sort: SystemProcessSort = .cpu
    /// 列表最多展示多少条（与面板/设置页一致）。
    var limit: Int = 20

    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 进程列表的筛选与排序（纯函数，便于回归）。
enum SystemProcessListFilter {
    static func apply(
        _ usages: [SystemProcessResourceUsage],
        query: SystemProcessListQuery
    ) -> [SystemProcessResourceUsage] {
        let search = query.normalizedSearchText
        let filtered = search.isEmpty ? usages : usages.filter { usage in
            usage.name.localizedCaseInsensitiveContains(search)
                || String(usage.pid).contains(search)
        }

        let sorted = filtered.sorted { lhs, rhs in
            switch query.sort {
            case .cpu:
                if lhs.cpuUsage != rhs.cpuUsage { return lhs.cpuUsage > rhs.cpuUsage }
            case .memory:
                if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
            case .disk:
                let lhsDisk = lhs.diskReadBytesPerSecond + lhs.diskWrittenBytesPerSecond
                let rhsDisk = rhs.diskReadBytesPerSecond + rhs.diskWrittenBytesPerSecond
                if lhsDisk != rhsDisk { return lhsDisk > rhsDisk }
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            // 同值或名称排序时保持稳定顺序：先按名称，再按 pid
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.pid < rhs.pid
        }
        return Array(sorted.prefix(max(query.limit, 1)))
    }
}

protocol SystemProcessResourceProviding: Sendable {
    func read() -> [SystemProcessResourceSample]
}

struct DefaultSystemProcessResourceProvider: SystemProcessResourceProviding {
    func read() -> [SystemProcessResourceSample] {
        allPIDs().compactMap(sample(for:))
    }

    private func allPIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size + 16
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    private func sample(for pid: pid_t) -> SystemProcessResourceSample? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        // 其他用户/系统进程读不到占用：跳过而不是报错。
        guard status == 0 else { return nil }
        return SystemProcessResourceSample(
            pid: pid,
            name: processName(for: pid),
            cpuTimeNanoseconds: usage.ri_user_time + usage.ri_system_time,
            memoryBytes: Int64(bitPattern: usage.ri_phys_footprint),
            diskReadBytes: Int64(bitPattern: usage.ri_diskio_bytesread),
            diskWrittenBytes: Int64(bitPattern: usage.ri_diskio_byteswritten)
        )
    }

    private func processName(for pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        if length > 0 {
            return String(cString: buffer)
        }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return "pid \(pid)" }
        return URL(fileURLWithPath: String(cString: pathBuffer)).lastPathComponent
    }
}

/// 采样并按查询条件提供进程占用排行。
@MainActor
@Observable
final class SystemProcessResourceService {
    static let shared = SystemProcessResourceService()

    private let provider: any SystemProcessResourceProviding
    private var previousSamples: [SystemProcessResourceSample] = []
    private var previousTimestamp: TimeInterval?
    private var samplingTask: Task<Void, Never>?

    private(set) var usages: [SystemProcessResourceUsage] = []
    var query = SystemProcessListQuery()

    var visibleUsages: [SystemProcessResourceUsage] {
        SystemProcessListFilter.apply(usages, query: query)
    }

    var isMonitoring: Bool { samplingTask != nil }

    init(provider: any SystemProcessResourceProviding = DefaultSystemProcessResourceProvider()) {
        self.provider = provider
    }

    func refresh(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let samples = provider.read()
        if let previousTimestamp {
            usages = SystemProcessResourceCalculator.usages(
                current: samples,
                previous: previousSamples,
                elapsed: now - previousTimestamp
            )
        }
        previousSamples = samples
        previousTimestamp = now
    }

    func beginMonitoring(interval: TimeInterval = SystemResourceSamplingPolicy.panelInterval) {
        guard samplingTask == nil else { return }
        refresh()
        // 首帧只建立基线，稍后按间隔给出速率。
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func endMonitoring() {
        samplingTask?.cancel()
        samplingTask = nil
        usages = []
        previousSamples = []
        previousTimestamp = nil
    }
}
