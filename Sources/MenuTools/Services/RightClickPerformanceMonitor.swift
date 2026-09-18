import Foundation

/// 菜单构建性能监控器
@MainActor
final class RightClickPerformanceMonitor {
    static let shared = RightClickPerformanceMonitor()
    
    private var startTime: Date?
    private var phaseTimes: [String: Double] = [:]
    
    func beginPhase(_ name: String) {
        if startTime == nil { startTime = Date() }
    }
    
    func endPhase(_ name: String) {
        guard let start = startTime else { return }
        let elapsed = Date().timeIntervalSince(start) * 1000 // ms
        
        phaseTimes[name] = elapsed
        
        if elapsed > 100 {
            RightClickLogger.performance("⚡ Menu build slow phase: \(name) took \(elapsed.rounded(.up))ms")
        }
    }
    
    func report() {
        guard let first = startTime else { return }
        
        let totalMs = (Date().timeIntervalSince(first) * 1000).rounded(.up)
        let entries = phaseTimes.map { "(\($0.key): \($0.value.rounded(.up))ms)" }.joined(separator: ", ")
        
        RightClickLogger.performance("📊 Menu total: \(totalMs)ms — phases: [\(entries)]")
        
        // 重置
        phaseTimes.removeAll()
    }
}
