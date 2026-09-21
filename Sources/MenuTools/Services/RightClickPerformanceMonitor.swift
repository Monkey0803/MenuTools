import Foundation

/// 菜单构建性能监控器。
///
/// FinderSync 在 Finder 的 XPC 线程上调用 `menu(for:)`，因此这里不能是 `@MainActor`；
/// 用锁保护状态，任何线程都能安全调用。
final class RightClickPerformanceMonitor: @unchecked Sendable {
    private let reportPerformance: @Sendable (String) -> Void
    private let lock = NSLock()
    private var startTime: Date?
    private var phaseTimes: [String: Double] = [:]

    init(reportPerformance: @escaping @Sendable (String) -> Void = RightClickLogger.performance) {
        self.reportPerformance = reportPerformance
    }

    /// 已记录的分段耗时（毫秒），供设置页与测试读取。
    var recordedPhaseTimes: [String: Double] {
        lock.withLock { phaseTimes }
    }

    func beginPhase(_ name: String) {
        lock.withLock {
            if startTime == nil { startTime = Date() }
        }
    }

    func endPhase(_ name: String) {
        let elapsed: Double? = lock.withLock {
            guard let start = startTime else { return nil }
            let value = Date().timeIntervalSince(start) * 1000 // ms
            phaseTimes[name] = value
            return value
        }

        guard let elapsed, elapsed > 100 else { return }
        reportPerformance("⚡ Menu build slow phase: \(name) took \(elapsed.rounded(.up))ms")
    }

    func report() {
        let summary: (totalMs: Int, entries: String)? = lock.withLock {
            guard let first = startTime else { return nil }
            let totalMs = Int((Date().timeIntervalSince(first) * 1000).rounded(.up))
            let entries = phaseTimes.map { "(\($0.key): \($0.value.rounded(.up))ms)" }.joined(separator: ", ")
            startTime = nil
            phaseTimes.removeAll()
            return (totalMs, entries)
        }

        guard let summary else { return }
        reportPerformance("📊 Menu total: \(summary.totalMs)ms — phases: [\(summary.entries)]")
    }
}
