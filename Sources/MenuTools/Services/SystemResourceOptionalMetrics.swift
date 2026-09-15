import Foundation
import IOKit

/// GPU 占用解析（纯函数，便于回归）。
enum SystemResourceGPUStatisticsParser {
    static let utilizationKey = "Device Utilization %"

    /// 从 IOAccelerator 的 PerformanceStatistics 里取占用百分比，换算成 0…1。
    /// 字段缺失或数值异常返回 nil（界面据此隐藏该项）。
    static func utilization(from statistics: [String: Any]) -> Double? {
        guard let value = statistics[utilizationKey] else { return nil }
        let percent: Double
        switch value {
        case let number as Double: percent = number
        case let number as NSNumber: percent = number.doubleValue
        case let text as String: percent = Double(text) ?? .nan
        default: return nil
        }
        guard percent.isFinite, percent >= 0, percent <= 1_000 else { return nil }
        return min(max(percent / 100, 0), 1)
    }
}

/// SMC 温度解码（纯函数，便于回归）。
enum SystemResourceSMCDecoder {
    /// sp78：有符号 7.8 定点，两字节大端。
    static func temperature(sp78 high: UInt8, _ low: UInt8) -> Double? {
        let raw = Int16(bitPattern: UInt16(high) << 8 | UInt16(low))
        let value = Double(raw) / 256
        // 合理范围之外的读数视为无效（0 或 0x8000 常见于无此传感器）
        guard value > -40, value < 150 else { return nil }
        return value
    }
}

/// 可选指标（温度 / GPU）：系统不允许时返回 nil，界面自动隐藏。
protocol SystemResourceOptionalMetricsReading: Sendable {
    func readGPUUsage() -> Double?
    func readTemperatureCelsius() -> Double?
}

struct DefaultSystemResourceOptionalMetricsReader: SystemResourceOptionalMetricsReading {
    /// SMC 通道是否可用：第一次探测后记住结果，不可用就不再重试。
    private static let smcProbe = SMCProbe()

    func readGPUUsage() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let statistics = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            if let utilization = SystemResourceGPUStatisticsParser.utilization(from: statistics) {
                return utilization
            }
        }
        return nil
    }

    func readTemperatureCelsius() -> Double? {
        Self.smcProbe.temperature()
    }
}

/// AppleSMC 只读探测：通道不可用时（部分 Apple 芯片 / 新系统）一次性判负并保持隐藏。
private final class SMCProbe: @unchecked Sendable {
    private struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct KeyData {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    /// 优先读 CPU 性能核温度，其次其它常见键；键名随芯片不同而不同。
    private static let candidateKeys = [
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0b", "Tp0f",
        "TC0P", "TC0D", "TC0E", "TC0F",
        "Tg0P", "Tg0D", "Te05", "Te0L"
    ]

    private let lock = NSLock()
    private var connection: io_connect_t = 0
    private var isAvailable: Bool?

    func temperature() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard openIfNeeded() else { return nil }
        for key in Self.candidateKeys {
            guard let info = keyInfo(key), info.dataSize > 0, info.dataSize <= 32 else { continue }
            guard let bytes = readBytes(key, size: info.dataSize) else { continue }
            if let value = SystemResourceSMCDecoder.temperature(sp78: bytes.0, bytes.1) {
                return value
            }
        }
        // 没有可用传感器：判负，避免每次采样都重试
        isAvailable = false
        return nil
    }

    private func openIfNeeded() -> Bool {
        if isAvailable == false { return false }
        if connection != 0 { return true }
        guard let matching = IOServiceMatching("AppleSMC") else {
            isAvailable = false
            return false
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            isAvailable = false
            return false
        }
        defer { IOObjectRelease(service) }
        var opened: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &opened) == KERN_SUCCESS, opened != 0 else {
            isAvailable = false
            return false
        }
        connection = opened
        return true
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outputSize = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(
            connection,
            UInt32(2),   // KERNEL_INDEX_SMC
            &input,
            MemoryLayout<KeyData>.stride,
            &output,
            &outputSize
        )
        guard result == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    private func keyInfo(_ key: String) -> KeyInfo? {
        var input = KeyData()
        input.key = Self.fourCharCode(key)
        input.data8 = 9   // SMC_CMD_READ_KEYINFO
        return call(&input)?.keyInfo
    }

    private func readBytes(_ key: String, size: UInt32) -> (UInt8, UInt8)? {
        var input = KeyData()
        input.key = Self.fourCharCode(key)
        input.keyInfo.dataSize = size
        input.data8 = 5   // SMC_CMD_READ_BYTES
        guard let output = call(&input) else { return nil }
        return (output.bytes.0, output.bytes.1)
    }

    private static func fourCharCode(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
