import Foundation
import XCTest
@testable import MenuTools

final class RightClickLoggerTests: XCTestCase {
    
    override func tearDown() {
        super.tearDown()
        // Clean up test log file
        try? FileManager.default.removeItem(at: RightClickLogger.logFile)
    }
    
    func test_logger_enabled_by_default() throws {
        XCTAssertEqual(RightClickLogger.isEnabled, UserDefaults.standard.bool(forKey: "rc_logger_enabled"))
    }
    
    func test_logger_can_enable_disable() throws {
        let original = RightClickLogger.isEnabled
        
        defer { 
            RightClickLogger.isEnabled = original 
        }
        
        RightClickLogger.enable()
        XCTAssertTrue(RightClickLogger.isEnabled)
        
        RightClickLogger.disable()
        XCTAssertFalse(RightClickLogger.isEnabled)
    }
    
    func test_logger_creates_directory() throws {
        _ = RightClickLogger.logDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: RightClickLogger.logDirectory.path))
    }
    
    func test_logger_creates_file_on_first_write() throws {
        // Force initialization
        RightClickLogger.enable()
        RightClickLogger.log("test")
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: RightClickLogger.logFile.path))
    }
    
    func test_logger_writes_to_file() throws {
        RightClickLogger.enable()
        RightClickLogger.log("Test message", level: .error)
        
        try await Task.sleep(for: .milliseconds(100)) // Wait for async write
        
        guard let content = try? String(contentsOf: RightClickLogger.logFile, encoding: .utf8) else {
            XCTFail("Log file should exist")
            return
        }
        
        XCTAssertGreaterThan(content.count, 0)
    }
    
    func test_logger_reads_recent_lines() throws {
        try await writeTestLogs(count: 50)
        
        let recent = RightClickLogger.readRecent(count: 10)
        XCTAssertEqual(recent.count, 10)
        XCTAssertGreaterThanOrEqual(recent.first?.count ?? 0, 20) // Has timestamp prefix
    }
    
    func test_logger_truncates_to_max_lines() throws {
        RightClickLogger.enable()
        
        for i in 0..<1500 {
            RightClickLogger.log("Line \(i)")
        }
        
        try await Task.sleep(for: .milliseconds(200))
        
        let content = try String(contentsOf: RightClickLogger.logFile, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter({ !$0.isEmpty })
        
        XCTAssertLessThanOrEqual(lines.count, Int(RightClickLogger.maxLogLines))
    }
    
    func test_logger_clears_file() throws {
        RightClickLogger.enable()
        RightClickLogger.log("Before clear")
        
        try await Task.sleep(for: .milliseconds(100))
        
        RightClickLogger.clear()
        XCTAssertTrue(!FileManager.default.fileExists(atPath: RightClickLogger.logFile.path))
    }
    
    // MARK: - Helpers
    
    private func writeTestLogs(count: Int) async throws {
        let data = (0..<count).map { "Line \($0)" }.joined(separator: "\n\n")
        try data.write(to: RightClickLogger.logFile, atomically: true, encoding: .utf8)
    }
}
