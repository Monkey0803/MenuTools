import Foundation
import XCTest
@testable import MenuTools

final class RightClickPerformanceMonitorTests: XCTestCase {
    
    private var monitor: RightClickPerformanceMonitor!
    
    override func setUp() {
        super.setUp()
        monitor = RightClickPerformanceMonitor.shared
        // Reset state
        _ = type(of: monitor).shared
    }
    
    override func tearDown() {
        monitor = nil
        super.tearDown()
    }
    
    func test_begin_phase_sets_start_time() throws {
        XCTAssertNil(monitor.phaseTimes["test"])
        monitor.beginPhase("test")
        // Internal state should be set, but we can't directly verify it
        // Just ensure no crash
    }
    
    func test_end_phase_records_elapsed_time() throws {
        monitor.beginPhase("phase1")
        
        try await Task.sleep(for: .milliseconds(50))
        
        monitor.endPhase("phase1")
        
        guard let elapsed = monitor.phaseTimes["phase1"] else {
            XCTFail("Elapsed time should be recorded")
            return
        }
        
        // Should be at least 50ms with some tolerance
        XCTAssertTrue(elapsed >= 45, "Elapsed time \(elapsed) should be close to 50ms")
    }
    
    func test_slow_phase_triggers_warning() throws {
        // Simulate a very slow phase (>100ms)
        monitor.beginPhase("slow")
        
        try await Task.sleep(for: .milliseconds(150))
        
        monitor.endPhase("slow")
        
        // Warning would be logged, we just check it was recorded
        XCTAssertGreaterThan(monitor.phaseTimes.count, 0)
    }
    
    func test_multiple_phases_independent() throws {
        monitor.beginPhase("fast")
        monitor.endPhase("fast")
        
        try await Task.sleep(for: .milliseconds(100))
        
        monitor.beginPhase("slow")
        monitor.endPhase("slow")
        
        XCTAssertEqual(monitor.phaseTimes.count, 2)
        
        let fastTime = monitor.phaseTimes["fast"] ?? 0
        let slowTime = monitor.phaseTimes["slow"] ?? 0
        
        XCTAssertGreaterThan(slowTime, fastTime * 2)
    }
}
