#!/usr/bin/swift
// 验证当前 macOS 的 nettop 输出、App 流量采样和长时间稳定性。
//
// 用法：
//   swift Scripts/test_network_traffic.swift [--duration 秒] [--interval 秒]
//       [--interface 范围] [--transport tcp|udp] [--connections] [--no-download] [--strict]
//
// 示例：
//   swift Scripts/test_network_traffic.swift --duration 30
//   swift Scripts/test_network_traffic.swift --duration 28800 --interval 10 --no-download --strict

import Foundation
import Darwin

struct Configuration {
    var duration: TimeInterval = 30
    var interval: TimeInterval = 2
    var interface: String?
    var transport: String?
    var includeConnections = false
    var generateDownload = true
    var strict = false
}

struct Sample {
    let elapsed: TimeInterval
    let processRows: Int
    let nonZeroRows: Int
    let outputBytes: Int
    let error: String?
}

private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ next: Data) {
        guard !next.isEmpty else { return }
        lock.lock()
        data.append(next)
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private func report(_ message: String) {
    print(message)
    fflush(stdout)
}

private func usage() -> Never {
    report("用法：swift Scripts/test_network_traffic.swift [--duration 秒] [--interval 秒] [--interface 范围] [--transport tcp|udp] [--connections] [--no-download] [--strict]")
    exit(64)
}

private func parseConfiguration() -> Configuration {
    var configuration = Configuration()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--duration":
            guard let value = arguments.first, let duration = TimeInterval(value), duration > 0 else { usage() }
            arguments.removeFirst()
            configuration.duration = duration
        case "--interval":
            guard let value = arguments.first, let interval = TimeInterval(value), interval >= 0.2 else { usage() }
            arguments.removeFirst()
            configuration.interval = interval
        case "--interface":
            guard let value = arguments.first, !value.isEmpty else { usage() }
            arguments.removeFirst()
            configuration.interface = value
        case "--transport":
            guard let value = arguments.first, ["tcp", "udp"].contains(value) else { usage() }
            arguments.removeFirst()
            configuration.transport = value
        case "--connections": configuration.includeConnections = true
        case "--no-download": configuration.generateDownload = false
        case "--strict": configuration.strict = true
        case "--help", "-h": usage()
        default: usage()
        }
    }
    return configuration
}

private func csvFields(_ line: Substring) -> [String] {
    var fields: [String] = []
    var field = ""
    var quoted = false
    var iterator = line.makeIterator()
    while let character = iterator.next() {
        if character == "\"" {
            quoted.toggle()
        } else if character == ",", !quoted {
            fields.append(field)
            field = ""
        } else {
            field.append(character)
        }
    }
    fields.append(field)
    return fields
}

private func runNettop(configuration: Configuration) -> Sample {
    var arguments = ["-P", "-L", "1", "-c", "-x", "-n", "-J", "bytes_in,bytes_out"]
    if configuration.includeConnections, let index = arguments.firstIndex(of: "-P") {
        arguments.remove(at: index)
    }
    if let transport = configuration.transport {
        arguments.append(contentsOf: ["-m", transport])
    }
    if let interface = configuration.interface {
        arguments.append(contentsOf: ["-t", interface])
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    process.arguments = arguments
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let output = DataCollector()
    let error = DataCollector()
    outputPipe.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
    errorPipe.fileHandleForReading.readabilityHandler = { error.append($0.availableData) }
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    let startedAt = Date()
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return Sample(elapsed: Date().timeIntervalSince(startedAt), processRows: 0, nonZeroRows: 0, outputBytes: 0, error: error.localizedDescription)
    }
    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil
    output.append(outputPipe.fileHandleForReading.availableData)
    error.append(errorPipe.fileHandleForReading.availableData)

    let outputString = String(data: output.value(), encoding: .utf8) ?? ""
    let errorString = String(data: error.value(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        return Sample(
            elapsed: Date().timeIntervalSince(startedAt),
            processRows: 0,
            nonZeroRows: 0,
            outputBytes: output.value().count,
            error: errorString.isEmpty ? "nettop 退出码 \(process.terminationStatus)" : errorString
        )
    }

    let rows = outputString.split(whereSeparator: \.isNewline).dropFirst().map(csvFields)
    let nonZeroRows = rows.filter { fields in
        guard fields.count >= 3 else { return false }
        return (Int64(fields[fields.count - 2]) ?? 0) > 0 || (Int64(fields[fields.count - 1]) ?? 0) > 0
    }.count
    return Sample(
        elapsed: Date().timeIntervalSince(startedAt),
        processRows: rows.count,
        nonZeroRows: nonZeroRows,
        outputBytes: output.value().count,
        error: nil
    )
}

private func generateDownload() {
    let semaphore = DispatchSemaphore(value: 0)
    let request = URLRequest(url: URL(string: "https://example.com/")!, timeoutInterval: 10)
    URLSession.shared.dataTask(with: request) { _, response, error in
        if let error {
            report("WARN: 生成下载流量失败：\(error.localizedDescription)")
        } else {
            report("已请求 \(response?.url?.host ?? "网络资源") 以产生验证流量")
        }
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 12)
}

let configuration = parseConfiguration()
report("网络流量 smoke test：时长 \(Int(configuration.duration))s，间隔 \(String(format: "%.1f", configuration.interval))s")
report("范围：\(configuration.interface ?? "external")，协议：\(configuration.transport ?? "tcp+udp")，连接明细：\(configuration.includeConnections ? "开" : "关")")

if configuration.generateDownload { generateDownload() }

let deadline = Date().addingTimeInterval(configuration.duration)
var samples: [Sample] = []
repeat {
    let sample = runNettop(configuration: configuration)
    samples.append(sample)
    let index = samples.count
    if let error = sample.error {
        report("[\(index)] FAIL \(String(format: "%.0f", sample.elapsed * 1_000))ms：\(error.trimmingCharacters(in: .whitespacesAndNewlines))")
    } else {
        report("[\(index)] \(String(format: "%.0f", sample.elapsed * 1_000))ms，进程行 \(sample.processRows)，非零行 \(sample.nonZeroRows)，输出 \(sample.outputBytes) B")
    }
    guard Date().addingTimeInterval(configuration.interval) < deadline else { break }
    Thread.sleep(forTimeInterval: configuration.interval)
} while Date() < deadline

let successful = samples.filter { $0.error == nil }
let observedTraffic = successful.contains { $0.nonZeroRows > 0 }
let averageMilliseconds = successful.isEmpty ? 0 : successful.map(\.elapsed).reduce(0, +) / Double(successful.count) * 1_000
let maximumMilliseconds = successful.map(\.elapsed).max() ?? 0
report("结果：\(successful.count)/\(samples.count) 次采样成功，观察到非零流量：\(observedTraffic ? "是" : "否")，平均 \(String(format: "%.0f", averageMilliseconds))ms，最大 \(String(format: "%.0f", maximumMilliseconds * 1_000))ms")

if successful.isEmpty {
    report("FAIL: 当前系统无法成功执行 nettop；请检查系统版本、权限与网络状态。")
    exit(1)
}
if configuration.strict && !observedTraffic {
    report("FAIL: 严格模式未观察到任何非零流量；请在下载或上传进行时重试。")
    exit(2)
}
report("PASS: nettop 可用；请在 MenuTools 中核对对应 App、速率和连接明细。")
