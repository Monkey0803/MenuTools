import Foundation
import Testing
@testable import MenuTools

@MainActor
@Suite("右键菜单操作日志", .serialized)
struct RightClickLoggerTests {
    @Test("日志开关跟随共享配置，扩展进程才读得到")
    func loggerFlagFollowsSharedConfig() {
        let original = RightClickLogger.isEnabled
        defer { RightClickLogger.apply(RightClickConfig(enabled: [:], loggerEnabled: original)) }

        RightClickLogger.apply(RightClickConfig(enabled: [:], loggerEnabled: true))
        #expect(RightClickLogger.isEnabled)

        RightClickLogger.apply(RightClickConfig(enabled: [:], loggerEnabled: false))
        #expect(!RightClickLogger.isEnabled)
    }

    @Test("未初始化时开关取自本进程的配置缓存")
    func loggerFlagResolvesFromConfigCache() {
        let config = RightClickConfigStore.load()
        RightClickLogger.apply(config)
        #expect(RightClickLogger.isEnabled == config.loggerEnabled)
    }

    @Test("日志文件与右键配置共享同一个基础目录")
    func logFileUsesSharedConfigurationBaseDirectory() {
        let base = URL(fileURLWithPath: "/tmp/MenuTools-RightClick-Group", isDirectory: true)
        #expect(
            RightClickLogger.logFileURL(inBaseDirectory: base).path
                == "/tmp/MenuTools-RightClick-Group/MenuTools/operations.log"
        )
    }

    @Test("扩展转送的日志只接受受限级别和大小")
    func forwardedLogPayloadIsValidatedBeforeWriting() {
        let payload = RightClickLogger.forwardedPayload(message: "Menu total: 12ms", level: "PERF")
        #expect(RightClickLogger.decodeForwardedPayload(payload) == .init(message: "Menu total: 12ms", level: "PERF"))
        #expect(RightClickLogger.forwardedPayload(message: "bad", level: "DEBUG") == nil)
        #expect(RightClickLogger.forwardedPayload(message: String(repeating: "x", count: 4_097), level: "PERF") == nil)
    }

    @Test("写入的日志可以按条数读回，clear 会删除日志文件")
    func writesReadsAndClearsLogFile() async throws {
        try await withIsolatedLogFile { file in
            let original = RightClickLogger.isEnabled
            defer { RightClickLogger.apply(RightClickConfig(enabled: [:], loggerEnabled: original)) }
            RightClickLogger.apply(RightClickConfig(enabled: [:], loggerEnabled: true))

            for index in 0..<5 {
                RightClickLogger.log("Line \(index)", level: "INFO")
            }

            let lines = try await waitForLogLines(atLeast: 5)
            #expect(lines.count == 5)
            #expect(RightClickLogger.readRecent(count: 3).count == 3)

            RightClickLogger.clear()
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    // MARK: - Helpers

    /// 备份真实日志文件，测试期间独占使用，结束后还原。
    private func withIsolatedLogFile(_ body: (URL) async throws -> Void) async throws {
        let file = RightClickLogger.logFile
        let backup = try? Data(contentsOf: file)
        defer {
            try? FileManager.default.removeItem(at: file)
            if let backup { try? backup.write(to: file) }
        }

        try? FileManager.default.removeItem(at: file)
        try await body(file)
    }

    private func waitForLogLines(atLeast count: Int) async throws -> [String] {
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: RightClickLogger.logFile.path),
               let content = try? String(contentsOf: RightClickLogger.logFile, encoding: .utf8) {
                let lines = content.split(separator: "\n").map(String.init)
                if lines.count >= count { return lines }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return RightClickLogger.readRecent(count: count)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<50 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
