import Foundation
import Testing
@testable import MenuTools

@MainActor
@Suite("右键菜单构建性能监控")
struct RightClickPerformanceMonitorTests {
    @Test("endPhase 记录该阶段的耗时")
    func recordsElapsedTimeForPhase() async throws {
        let monitor = RightClickPerformanceMonitor()
        monitor.beginPhase("phase1")
        try await Task.sleep(for: .milliseconds(50))
        monitor.endPhase("phase1")

        let elapsed = try #require(monitor.recordedPhaseTimes["phase1"])
        #expect(elapsed >= 45, "阶段耗时 \(elapsed)ms 应接近 50ms")
    }

    @Test("没有 beginPhase 时 endPhase 不记录")
    func endPhaseWithoutBeginRecordsNothing() {
        let monitor = RightClickPerformanceMonitor()
        monitor.endPhase("ghost")

        #expect(monitor.recordedPhaseTimes["ghost"] == nil)
    }

    @Test("report 汇总后清空分段记录")
    func reportClearsRecordedPhases() {
        let monitor = RightClickPerformanceMonitor()
        monitor.beginPhase("only")
        monitor.endPhase("only")
        #expect(monitor.recordedPhaseTimes.count == 1)

        monitor.report()

        #expect(monitor.recordedPhaseTimes.isEmpty)
    }

    @Test("report 完成一次测量后不沿用旧菜单的起始时间")
    func reportResetsMeasurementSession() {
        let monitor = RightClickPerformanceMonitor()
        monitor.beginPhase("first")
        monitor.endPhase("first")
        monitor.report()

        // 第二次菜单尚未开始时不能写入任何阶段数据；否则会把上一轮的时间混入本轮。
        monitor.endPhase("stale")
        #expect(monitor.recordedPhaseTimes["stale"] == nil)
    }

    @Test("汇总通过注入的上报器输出，扩展可转交给主 App")
    func reportUsesInjectedReporter() {
        let records = RightClickLockedState([String]())
        let monitor = RightClickPerformanceMonitor { message in
            records.mutate { $0.append(message) }
        }
        monitor.beginPhase("menu_start")
        monitor.endPhase("menu_render")
        monitor.report()

        #expect(records.read().count == 1)
        #expect(records.read()[0].contains("Menu total:"))
    }
}
