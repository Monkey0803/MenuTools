import AppKit
import Darwin
import Foundation
import Observation
import SQLite3
import UserNotifications

struct NetworkTrafficInterfaceAddress: Equatable, Sendable {
    let interfaceName: String
    let address: String
    let isIPv6: Bool
    let isUp: Bool
}

struct NetworkTrafficInterfaceInfo: Equatable, Sendable {
    let name: String
    let ipv4: String?
    let ipv6: String?
    let isVPN: Bool
}

enum NetworkTrafficInterfaceInspector {
    static func summarize(_ addresses: [NetworkTrafficInterfaceAddress]) -> [NetworkTrafficInterfaceInfo] {
        var grouped: [String: (ipv4: String?, ipv6: String?)] = [:]
        for address in addresses where address.isUp && !address.interfaceName.hasPrefix("lo") {
            var current = grouped[address.interfaceName] ?? (nil, nil)
            if address.isIPv6 {
                current.ipv6 = current.ipv6 ?? address.address
            } else {
                current.ipv4 = current.ipv4 ?? address.address
            }
            grouped[address.interfaceName] = current
        }

        return grouped.map { name, values in
            NetworkTrafficInterfaceInfo(
                name: name,
                ipv4: values.ipv4,
                ipv6: values.ipv6,
                isVPN: isVPN(name)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isVPN != rhs.isVPN { return !lhs.isVPN }
            return lhs.name < rhs.name
        }
    }

    static func read() -> [NetworkTrafficInterfaceInfo] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return [] }
        defer { freeifaddrs(pointer) }

        var addresses: [NetworkTrafficInterfaceAddress] = []
        var current = pointer
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            addresses.append(NetworkTrafficInterfaceAddress(
                interfaceName: String(cString: interface.pointee.ifa_name),
                address: String(decoding: bytes, as: UTF8.self),
                isIPv6: family == AF_INET6,
                isUp: (interface.pointee.ifa_flags & UInt32(IFF_UP)) != 0
            ))
        }
        return summarize(addresses)
    }

    private static func isVPN(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("tun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec")
    }
}

enum NetworkTrafficInterface: String, CaseIterable, Codable, Sendable {
    case all
    case external
    case wifi
    case wired
    case awdl
    case expensive
    case loopback
    case undefined

    var titleKey: String {
        switch self {
        case .all: return "traffic.interface.all"
        case .external: return "traffic.interface.external"
        case .wifi: return "traffic.interface.wifi"
        case .wired: return "traffic.interface.wired"
        case .awdl: return "traffic.interface.awdl"
        case .expensive: return "traffic.interface.expensive"
        case .loopback: return "traffic.interface.loopback"
        case .undefined: return "traffic.interface.undefined"
        }
    }
}

enum NetworkTrafficTransport: String, CaseIterable, Codable, Sendable {
    case all
    case tcp
    case udp

    var titleKey: String {
        switch self {
        case .all: return "traffic.transport.all"
        case .tcp: return "traffic.transport.tcp"
        case .udp: return "traffic.transport.udp"
        }
    }
}

enum NetworkTrafficHistoryRange: String, CaseIterable, Codable, Sendable {
    case hour
    case day
    case week
    case month

    var titleKey: String {
        switch self {
        case .hour: return "traffic.range.hour"
        case .day: return "traffic.range.day"
        case .week: return "traffic.range.week"
        case .month: return "traffic.range.month"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .hour: return 60
        case .day: return 20 * 60
        case .week: return 2 * 60 * 60
        case .month: return 12 * 60 * 60
        }
    }

    var pointCount: Int {
        switch self {
        case .hour: return 60
        case .day: return 72
        case .week: return 84
        case .month: return 60
        }
    }
}

struct NetworkTrafficHistoryPoint: Equatable, Sendable {
    let timestamp: Date
    let downloadedBytes: Int64
    let uploadedBytes: Int64

    var bytes: Int64 {
        NetworkTrafficMath.clampedAdd(downloadedBytes, uploadedBytes)
    }
}

enum NetworkTrafficHistorySeries {
    static func make(
        from buckets: [NetworkTrafficHistoryBucket],
        range: NetworkTrafficHistoryRange,
        now: Date,
        appIDs: Set<String>? = nil
    ) -> [NetworkTrafficHistoryPoint] {
        let interval = range.interval
        let end = floor(now.timeIntervalSince1970 / interval) * interval
        let start = end - interval * Double(range.pointCount - 1)
        var downloadedValues = Array(repeating: Int64(0), count: range.pointCount)
        var uploadedValues = Array(repeating: Int64(0), count: range.pointCount)

        for bucket in buckets {
            let bucketTime = bucket.timestamp.timeIntervalSince1970
            let index = Int(floor((bucketTime - start) / interval))
            guard downloadedValues.indices.contains(index) else { continue }
            let samples = bucket.apps.values.filter { sample in
                appIDs?.contains(sample.identity.id) ?? true
            }
            let downloaded = samples.reduce(Int64(0)) {
                NetworkTrafficMath.clampedAdd($0, $1.downloadedBytes)
            }
            let uploaded = samples.reduce(Int64(0)) {
                NetworkTrafficMath.clampedAdd($0, $1.uploadedBytes)
            }
            downloadedValues[index] = NetworkTrafficMath.clampedAdd(downloadedValues[index], downloaded)
            uploadedValues[index] = NetworkTrafficMath.clampedAdd(uploadedValues[index], uploaded)
        }

        return downloadedValues.indices.map { index in
            NetworkTrafficHistoryPoint(
                timestamp: Date(timeIntervalSince1970: start + Double(index) * interval),
                downloadedBytes: downloadedValues[index],
                uploadedBytes: uploadedValues[index]
            )
        }
    }
}

struct NetworkTrafficHistoryRankingEntry: Equatable, Identifiable, Sendable {
    let identity: NetworkAppIdentity
    let downloadedBytes: Int64
    let uploadedBytes: Int64

    var id: String { identity.id }
    var totalBytes: Int64 {
        NetworkTrafficMath.clampedAdd(downloadedBytes, uploadedBytes)
    }
}

enum NetworkTrafficHistoryRanking {
    static func make(
        from buckets: [NetworkTrafficHistoryBucket],
        range: NetworkTrafficHistoryRange,
        queryKey: String = NetworkTrafficQuery.default.storageKey,
        now: Date,
        appIDs: Set<String>? = nil
    ) -> [NetworkTrafficHistoryRankingEntry] {
        let start = now.addingTimeInterval(-range.interval * Double(range.pointCount))
        var entries: [String: NetworkTrafficHistoryRankingEntry] = [:]
        for bucket in buckets where bucket.queryKey == queryKey && bucket.timestamp >= start && bucket.timestamp <= now {
            for sample in bucket.apps.values where appIDs?.contains(sample.identity.id) ?? true {
                let current = entries[sample.identity.id]
                entries[sample.identity.id] = NetworkTrafficHistoryRankingEntry(
                    identity: sample.identity,
                    downloadedBytes: NetworkTrafficMath.clampedAdd(current?.downloadedBytes ?? 0, sample.downloadedBytes),
                    uploadedBytes: NetworkTrafficMath.clampedAdd(current?.uploadedBytes ?? 0, sample.uploadedBytes)
                )
            }
        }
        return entries.values.sorted {
            if $0.totalBytes == $1.totalBytes {
                return $0.identity.displayName.localizedCaseInsensitiveCompare($1.identity.displayName) == .orderedAscending
            }
            return $0.totalBytes > $1.totalBytes
        }
    }
}

struct NetworkTrafficHistoryStats: Equatable, Sendable {
    let totalBytes: Int64
    let peakBytes: Int64
    let averageBytes: Int64

    static func make(
        from buckets: [NetworkTrafficHistoryBucket],
        range: NetworkTrafficHistoryRange,
        now: Date,
        appIDs: Set<String>? = nil
    ) -> NetworkTrafficHistoryStats {
        let points = NetworkTrafficHistorySeries.make(
            from: buckets,
            range: range,
            now: now,
            appIDs: appIDs
        )
        let totalBytes = points.reduce(Int64(0)) {
            NetworkTrafficMath.clampedAdd($0, $1.bytes)
        }
        let averageBytes = points.isEmpty
            ? 0
            : Int64(Double(totalBytes) / Double(points.count))
        return NetworkTrafficHistoryStats(
            totalBytes: totalBytes,
            peakBytes: points.map(\.bytes).max() ?? 0,
            averageBytes: averageBytes
        )
    }
}

enum NetworkTrafficCalendarPeriod: Sendable {
    case today
    case month
}

struct NetworkTrafficPeriodSummary: Equatable, Sendable {
    let downloadedBytes: Int64
    let uploadedBytes: Int64

    var totalBytes: Int64 {
        NetworkTrafficMath.clampedAdd(downloadedBytes, uploadedBytes)
    }

    static func make(
        from buckets: [NetworkTrafficHistoryBucket],
        period: NetworkTrafficCalendarPeriod,
        queryKey: String = NetworkTrafficQuery.default.storageKey,
        now: Date = Date(),
        calendar: Calendar = .current,
        appIDs: Set<String>? = nil
    ) -> NetworkTrafficPeriodSummary {
        let start: Date
        switch period {
        case .today:
            start = calendar.startOfDay(for: now)
        case .month:
            start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        }
        return buckets
            .filter { $0.queryKey == queryKey && $0.timestamp >= start && $0.timestamp <= now }
            .flatMap(\.apps.values)
            .filter { appIDs?.contains($0.identity.id) ?? true }
            .reduce(NetworkTrafficPeriodSummary(downloadedBytes: 0, uploadedBytes: 0)) { result, sample in
                NetworkTrafficPeriodSummary(
                    downloadedBytes: NetworkTrafficMath.clampedAdd(result.downloadedBytes, sample.downloadedBytes),
                    uploadedBytes: NetworkTrafficMath.clampedAdd(result.uploadedBytes, sample.uploadedBytes)
                )
            }
    }
}

enum NetworkTrafficQuotaStage: Int, Codable, Comparable, Sendable {
    case none = 0
    case eightyPercent = 80
    case full = 100

    static func < (lhs: NetworkTrafficQuotaStage, rhs: NetworkTrafficQuotaStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum NetworkTrafficQuotaPolicy {
    static func stage(usedBytes: Int64, quotaBytes: Int64) -> NetworkTrafficQuotaStage {
        guard quotaBytes > 0, usedBytes >= 0 else { return .none }
        if usedBytes >= quotaBytes { return .full }
        let eightyPercent = Double(quotaBytes) * 0.8
        return Double(usedBytes) >= eightyPercent ? .eightyPercent : .none
    }
}

enum NetworkTrafficMenuBarDisplayMode: String, CaseIterable, Codable, Sendable {
    case off
    case total
    case upDown

    var titleKey: String {
        switch self {
        case .off: return "traffic.menuBar.off"
        case .total: return "traffic.menuBar.total"
        case .upDown: return "traffic.menuBar.upDown"
        }
    }
}

enum NetworkTrafficMenuBarPresenter {
    static func title(
        snapshot: NetworkTrafficSnapshot,
        mode: NetworkTrafficMenuBarDisplayMode
    ) -> String? {
        guard mode != .off, snapshot.isAvailable else { return nil }
        let summary = NetworkTrafficSummary.make(snapshot.apps.filter { !$0.isHistoricalOnly })
        switch mode {
        case .off:
            return nil
        case .total:
            return "↕ \(compactRate(summary.currentBytesPerSecond))"
        case .upDown:
            return "↓ \(compactRate(summary.downloadBytesPerSecond))  ↑ \(compactRate(summary.uploadBytesPerSecond))"
        }
    }

    private static func compactRate(_ bytesPerSecond: Int64) -> String {
        let value = max(bytesPerSecond, 0)
        if value >= 1_024 * 1_024 * 1_024 {
            return String(format: "%.1f GB/s", locale: Locale(identifier: "en_US_POSIX"), Double(value) / 1_073_741_824)
        }
        if value >= 1_024 * 1_024 {
            return String(format: "%.1f MB/s", locale: Locale(identifier: "en_US_POSIX"), Double(value) / 1_048_576)
        }
        if value >= 1_024 {
            return "\(value / 1_024) KB/s"
        }
        return "\(value) B/s"
    }
}

struct NetworkTrafficQuery: Codable, Equatable, Sendable {
    var interface: NetworkTrafficInterface
    var transport: NetworkTrafficTransport

    static let `default` = NetworkTrafficQuery(interface: .external, transport: .all)

    init(interface: NetworkTrafficInterface, transport: NetworkTrafficTransport) {
        self.interface = interface
        self.transport = transport
    }

    var storageKey: String {
        "\(interface.rawValue):\(transport.rawValue)"
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let interface = NetworkTrafficInterface(rawValue: parts[0]),
              let transport = NetworkTrafficTransport(rawValue: parts[1]) else {
            return nil
        }
        self.init(interface: interface, transport: transport)
    }

    var commandArguments: [String] {
        var arguments = ["-P", "-L", "1", "-c", "-x", "-n", "-J", "bytes_in,bytes_out"]
        if transport != .all {
            arguments.append(contentsOf: ["-m", transport.rawValue])
        }
        if interface != .all {
            arguments.append(contentsOf: ["-t", interface.rawValue])
        }
        return arguments
    }
}

enum NetworkTrafficReadStatus: String, Codable, Equatable, Sendable {
    case available
    case commandUnavailable
    case permissionDenied
    case malformedOutput
    case commandFailed
    case timedOut
}

enum NetworkTrafficAppKind: String, Codable, CaseIterable, Sendable {
    case application
    case systemService
    case unknown

    var titleKey: String {
        switch self {
        case .application: return "traffic.kind.application"
        case .systemService: return "traffic.kind.systemService"
        case .unknown: return "traffic.kind.unknown"
        }
    }
}

/// 用 Bundle ID 或完整可执行文件路径标识一个 App，避免仅按显示名称误合并。
struct NetworkAppIdentity: Codable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let bundleIdentifier: String?
    let bundlePath: String?
    let executablePath: String?
    let kind: NetworkTrafficAppKind

    static func fallback(processName: String) -> NetworkAppIdentity {
        NetworkAppIdentity(
            id: "process:\(processName)",
            displayName: processName,
            bundleIdentifier: nil,
            bundlePath: nil,
            executablePath: nil,
            kind: .unknown
        )
    }
}

/// nettop 返回的单个进程累计流量。
struct NetworkAppTrafficReading: Codable, Equatable, Sendable {
    let identity: NetworkAppIdentity
    let pid: Int32
    let receivedBytes: Int64
    let sentBytes: Int64

    init(
        identity: NetworkAppIdentity,
        pid: Int32,
        receivedBytes: Int64,
        sentBytes: Int64
    ) {
        self.identity = identity
        self.pid = pid
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }

    init(appName: String, pid: Int32, receivedBytes: Int64, sentBytes: Int64) {
        self.init(
            identity: .fallback(processName: appName),
            pid: pid,
            receivedBytes: receivedBytes,
            sentBytes: sentBytes
        )
    }

    var appName: String { identity.displayName }
}

struct NetworkConnectionTrafficReading: Codable, Equatable, Sendable {
    let identity: NetworkAppIdentity
    let pid: Int32
    let transport: NetworkTrafficTransport
    let endpoint: String
    let receivedBytes: Int64
    let sentBytes: Int64
}

/// 一次 nettop 进程流量采样。
struct NetworkTrafficReading: Equatable, Sendable {
    let timestamp: TimeInterval
    let apps: [NetworkAppTrafficReading]
    let connections: [NetworkConnectionTrafficReading]
    let status: NetworkTrafficReadStatus

    init(
        timestamp: TimeInterval,
        apps: [NetworkAppTrafficReading],
        connections: [NetworkConnectionTrafficReading] = [],
        status: NetworkTrafficReadStatus
    ) {
        self.timestamp = timestamp
        self.apps = apps
        self.connections = connections
        self.status = status
    }

    init(timestamp: TimeInterval, apps: [NetworkAppTrafficReading], isAvailable: Bool) {
        self.init(
            timestamp: timestamp,
            apps: apps,
            connections: [],
            status: isAvailable ? .available : .malformedOutput
        )
    }

    var isAvailable: Bool { status == .available }
}

struct NetworkTrafficSessionTotal: Codable, Equatable, Sendable {
    let downloadedBytes: Int64
    let uploadedBytes: Int64
}

struct NetworkTrafficSummary: Equatable, Sendable {
    let downloadBytesPerSecond: Int64
    let uploadBytesPerSecond: Int64
    let sessionDownloadedBytes: Int64
    let sessionUploadedBytes: Int64

    var currentBytesPerSecond: Int64 {
        NetworkTrafficMath.clampedAdd(downloadBytesPerSecond, uploadBytesPerSecond)
    }

    static func make(_ apps: [NetworkAppTrafficSnapshot]) -> NetworkTrafficSummary {
        NetworkTrafficSummary(
            downloadBytesPerSecond: apps.reduce(0) {
                NetworkTrafficMath.clampedAdd($0, $1.downloadBytesPerSecond)
            },
            uploadBytesPerSecond: apps.reduce(0) {
                NetworkTrafficMath.clampedAdd($0, $1.uploadBytesPerSecond)
            },
            sessionDownloadedBytes: apps.reduce(0) {
                NetworkTrafficMath.clampedAdd($0, $1.sessionDownloadedBytes)
            },
            sessionUploadedBytes: apps.reduce(0) {
                NetworkTrafficMath.clampedAdd($0, $1.sessionUploadedBytes)
            }
        )
    }
}

struct NetworkProcessTrafficSnapshot: Codable, Equatable, Identifiable, Sendable {
    let pid: Int32
    let processName: String
    let downloadBytesPerSecond: Int64
    let uploadBytesPerSecond: Int64
    let currentDownloadedBytes: Int64
    let currentUploadedBytes: Int64

    var id: Int32 { pid }
}

struct NetworkEndpointComponents: Equatable, Sendable {
    let host: String
    let port: Int?
    let localHost: String?
    let localPort: Int?

    init(host: String, port: Int?, localHost: String? = nil, localPort: Int? = nil) {
        self.host = host
        self.port = port
        self.localHost = localHost
        self.localPort = localPort
    }
}

enum NetworkEndpointParser {
    static func parse(_ endpoint: String) -> NetworkEndpointComponents {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = value.range(of: "<->") {
            let local = parseSingle(String(value[..<separator.lowerBound]))
            let remote = parseSingle(String(value[separator.upperBound...]))
            return NetworkEndpointComponents(
                host: remote.host,
                port: remote.port,
                localHost: local.host,
                localPort: local.port
            )
        }
        return parseSingle(value)
    }

    private static func parseSingle(_ value: String) -> NetworkEndpointComponents {
        if value.hasPrefix("["), let closingBracket = value.firstIndex(of: "]") {
            let hostStart = value.index(after: value.startIndex)
            let host = String(value[hostStart..<closingBracket])
            let suffix = String(value[value.index(after: closingBracket)...])
            let port = Int(suffix.drop(while: { $0 == ":" }))
            return NetworkEndpointComponents(host: host, port: port)
        }

        let colonCount = value.filter { $0 == ":" }.count
        guard colonCount == 1, let separator = value.lastIndex(of: ":") else {
            return NetworkEndpointComponents(host: value, port: nil)
        }
        let port = Int(value[value.index(after: separator)...])
        return NetworkEndpointComponents(
            host: String(value[..<separator]),
            port: port
        )
    }
}

struct NetworkConnectionTrafficSnapshot: Codable, Equatable, Identifiable, Sendable {
    let transport: NetworkTrafficTransport
    let endpoint: String
    let downloadedBytes: Int64
    let uploadedBytes: Int64

    var id: String { "\(transport.rawValue):\(endpoint)" }

    var components: NetworkEndpointComponents {
        NetworkEndpointParser.parse(endpoint)
    }
}

enum NetworkConnectionTrafficAggregator {
    private struct Key: Hashable {
        let transport: NetworkTrafficTransport
        let endpoint: String
    }

    static func snapshots(
        from readings: [NetworkConnectionTrafficReading]
    ) -> [NetworkConnectionTrafficSnapshot] {
        let totals = readings.reduce(into: [Key: (downloaded: Int64, uploaded: Int64)]()) { result, reading in
            let key = Key(transport: reading.transport, endpoint: reading.endpoint)
            let current = result[key] ?? (0, 0)
            result[key] = (
                NetworkTrafficMath.clampedAdd(current.downloaded, reading.receivedBytes),
                NetworkTrafficMath.clampedAdd(current.uploaded, reading.sentBytes)
            )
        }
        return totals.map { key, value in
            NetworkConnectionTrafficSnapshot(
                transport: key.transport,
                endpoint: key.endpoint,
                downloadedBytes: value.downloaded,
                uploadedBytes: value.uploaded
            )
        }
        .sorted {
            if $0.transport != $1.transport { return $0.transport.rawValue < $1.transport.rawValue }
            return $0.endpoint < $1.endpoint
        }
    }
}

/// 面板展示的单个 App 流量快照；同一 App 的多个进程已合并，同时保留进程明细。
struct NetworkAppTrafficSnapshot: Codable, Equatable, Identifiable, Sendable {
    let identity: NetworkAppIdentity
    let downloadBytesPerSecond: Int64
    let uploadBytesPerSecond: Int64
    let sessionDownloadedBytes: Int64
    let sessionUploadedBytes: Int64
    let processes: [NetworkProcessTrafficSnapshot]
    let connections: [NetworkConnectionTrafficSnapshot]
    let isHistoricalOnly: Bool

    init(
        identity: NetworkAppIdentity,
        downloadBytesPerSecond: Int64,
        uploadBytesPerSecond: Int64,
        sessionDownloadedBytes: Int64,
        sessionUploadedBytes: Int64,
        processes: [NetworkProcessTrafficSnapshot] = [],
        connections: [NetworkConnectionTrafficSnapshot] = [],
        isHistoricalOnly: Bool = false
    ) {
        self.identity = identity
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.sessionDownloadedBytes = sessionDownloadedBytes
        self.sessionUploadedBytes = sessionUploadedBytes
        self.processes = processes
        self.connections = connections
        self.isHistoricalOnly = isHistoricalOnly
    }

    init(
        appName: String,
        downloadBytesPerSecond: Int64,
        uploadBytesPerSecond: Int64,
        sessionDownloadedBytes: Int64,
        sessionUploadedBytes: Int64
    ) {
        self.init(
            identity: .fallback(processName: appName),
            downloadBytesPerSecond: downloadBytesPerSecond,
            uploadBytesPerSecond: uploadBytesPerSecond,
            sessionDownloadedBytes: sessionDownloadedBytes,
            sessionUploadedBytes: sessionUploadedBytes
        )
    }

    var id: String { identity.id }
    var appName: String { identity.displayName }
    var currentBytesPerSecond: Int64 {
        NetworkTrafficMath.clampedAdd(downloadBytesPerSecond, uploadBytesPerSecond)
    }

    func replacingConnections(_ connections: [NetworkConnectionTrafficSnapshot]) -> NetworkAppTrafficSnapshot {
        NetworkAppTrafficSnapshot(
            identity: identity,
            downloadBytesPerSecond: downloadBytesPerSecond,
            uploadBytesPerSecond: uploadBytesPerSecond,
            sessionDownloadedBytes: sessionDownloadedBytes,
            sessionUploadedBytes: sessionUploadedBytes,
            processes: processes,
            connections: connections,
            isHistoricalOnly: isHistoricalOnly
        )
    }
}

struct NetworkTrafficDelta: Equatable, Sendable {
    let identity: NetworkAppIdentity
    let downloadedBytes: Int64
    let uploadedBytes: Int64
}

struct NetworkTrafficCalculationResult: Equatable, Sendable {
    let apps: [NetworkAppTrafficSnapshot]
    let sessionTotals: [String: NetworkTrafficSessionTotal]
    let deltas: [NetworkTrafficDelta]
}

struct NetworkTrafficHistoryAppSample: Codable, Equatable, Sendable {
    var identity: NetworkAppIdentity
    var downloadedBytes: Int64
    var uploadedBytes: Int64
}

struct NetworkTrafficHistoryBucket: Codable, Equatable, Identifiable, Sendable {
    let timestamp: Date
    let queryKey: String
    var apps: [String: NetworkTrafficHistoryAppSample]

    var id: String { "\(queryKey):\(timestamp.timeIntervalSince1970)" }
}

/// 以分钟为粒度增量保存最近 30 天的历史流量。
///
/// App 元数据与分钟计数分表存储，避免旧版 JSON 在每个分钟桶中重复保存路径等长字符串，
/// WAL 也让追加采样不再每次原子重写整份历史文件。
protocol NetworkTrafficHistoryStoring: AnyObject {
    func load(queryKey: String?) -> [NetworkTrafficHistoryBucket]
    func save(_ buckets: [NetworkTrafficHistoryBucket])
    func clear(queryKey: String)
}

final class NetworkTrafficHistoryStore: NetworkTrafficHistoryStoring {
    private let fileURL: URL
    private let legacyFileURL: URL?
    private let now: () -> Date
    private let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    init(
        fileURL: URL? = nil,
        legacyFileURL: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        if let fileURL {
            self.fileURL = fileURL
            self.legacyFileURL = legacyFileURL
        } else {
            self.fileURL = Self.defaultFileURL()
            self.legacyFileURL = legacyFileURL ?? Self.legacyFileURL()
        }
        self.now = now
    }

    func load(queryKey: String? = nil) -> [NetworkTrafficHistoryBucket] {
        withDatabase(default: []) { database in
            migrateLegacyHistoryIfNeeded(database)
            pruneExpiredRows(database)

            let queryClause = queryKey == nil ? "" : " AND s.query_key = ?"
            let sql = """
            SELECT s.query_key,
                   CASE
                       WHEN s.bucket_timestamp >= ? THEN s.bucket_timestamp
                       ELSE CAST(s.bucket_timestamp / 7200 AS INTEGER) * 7200
                   END AS display_timestamp,
                   s.app_id,
                   SUM(s.downloaded_bytes), SUM(s.uploaded_bytes),
                   i.display_name, i.bundle_identifier, i.bundle_path,
                   i.executable_path, i.kind
            FROM traffic_samples AS s
            JOIN app_identities AS i ON i.id = s.app_id
            WHERE s.bucket_timestamp >= ?\(queryClause)
            GROUP BY s.query_key, display_timestamp, s.app_id
            ORDER BY display_timestamp ASC, s.query_key ASC, s.app_id ASC
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, now().addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, cutoffDate().timeIntervalSince1970)
            if let queryKey {
                bind(queryKey, to: statement, column: 3)
            }

            struct BucketKey: Hashable {
                let timestamp: TimeInterval
                let queryKey: String
            }
            var buckets: [BucketKey: NetworkTrafficHistoryBucket] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let timestamp = sqlite3_column_double(statement, 1)
                let queryKey = text(statement, column: 0)
                let appID = text(statement, column: 2)
                let identity = NetworkAppIdentity(
                    id: appID,
                    displayName: text(statement, column: 5),
                    bundleIdentifier: optionalText(statement, column: 6),
                    bundlePath: optionalText(statement, column: 7),
                    executablePath: optionalText(statement, column: 8),
                    kind: NetworkTrafficAppKind(rawValue: text(statement, column: 9)) ?? .unknown
                )
                let key = BucketKey(timestamp: timestamp, queryKey: queryKey)
                var bucket = buckets[key] ?? NetworkTrafficHistoryBucket(
                    timestamp: Date(timeIntervalSince1970: timestamp),
                    queryKey: queryKey,
                    apps: [:]
                )
                bucket.apps[appID] = NetworkTrafficHistoryAppSample(
                    identity: identity,
                    downloadedBytes: sqlite3_column_int64(statement, 3),
                    uploadedBytes: sqlite3_column_int64(statement, 4)
                )
                buckets[key] = bucket
            }
            return buckets.values.sorted {
                if $0.timestamp == $1.timestamp { return $0.queryKey < $1.queryKey }
                return $0.timestamp < $1.timestamp
            }
        }
    }

    func save(_ buckets: [NetworkTrafficHistoryBucket]) {
        withDatabase(default: ()) { database in
            execute(database, "BEGIN IMMEDIATE TRANSACTION")
            write(buckets.filter { $0.timestamp >= cutoffDate() }, to: database)
            pruneExpiredRows(database)
            execute(database, "COMMIT")
        }
    }

    func clear(queryKey: String) {
        withDatabase(default: ()) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "DELETE FROM traffic_samples WHERE query_key = ?",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            bind(queryKey, to: statement, column: 1)
            _ = sqlite3_step(statement)
        }
    }

    private func withDatabase<T>(default defaultValue: T, _ body: (OpaquePointer) -> T) -> T {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return defaultValue
        }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return defaultValue
        }
        defer { sqlite3_close(database) }
        configure(database)
        return body(database)
    }

    private func configure(_ database: OpaquePointer) {
        execute(database, "PRAGMA journal_mode=WAL")
        execute(database, "PRAGMA synchronous=NORMAL")
        execute(database, "PRAGMA foreign_keys=ON")
        execute(database, """
            CREATE TABLE IF NOT EXISTS app_identities (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                bundle_identifier TEXT,
                bundle_path TEXT,
                executable_path TEXT,
                kind TEXT NOT NULL
            )
            """)
        execute(database, """
            CREATE TABLE IF NOT EXISTS traffic_samples (
                query_key TEXT NOT NULL,
                bucket_timestamp REAL NOT NULL,
                app_id TEXT NOT NULL REFERENCES app_identities(id) ON DELETE CASCADE,
                downloaded_bytes INTEGER NOT NULL,
                uploaded_bytes INTEGER NOT NULL,
                PRIMARY KEY (query_key, bucket_timestamp, app_id)
            ) WITHOUT ROWID
            """)
        execute(database, "CREATE INDEX IF NOT EXISTS traffic_samples_timestamp ON traffic_samples(bucket_timestamp)")
        execute(database, "CREATE TABLE IF NOT EXISTS traffic_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }

    private func write(_ buckets: [NetworkTrafficHistoryBucket], to database: OpaquePointer) {
        let identitySQL = """
            INSERT INTO app_identities
                (id, display_name, bundle_identifier, bundle_path, executable_path, kind)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name=excluded.display_name,
                bundle_identifier=excluded.bundle_identifier,
                bundle_path=excluded.bundle_path,
                executable_path=excluded.executable_path,
                kind=excluded.kind
            """
        let sampleSQL = """
            INSERT INTO traffic_samples
                (query_key, bucket_timestamp, app_id, downloaded_bytes, uploaded_bytes)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(query_key, bucket_timestamp, app_id) DO UPDATE SET
                downloaded_bytes=excluded.downloaded_bytes,
                uploaded_bytes=excluded.uploaded_bytes
            """
        var identityStatement: OpaquePointer?
        var sampleStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, identitySQL, -1, &identityStatement, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database, sampleSQL, -1, &sampleStatement, nil) == SQLITE_OK,
              let identityStatement, let sampleStatement else {
            if let identityStatement { sqlite3_finalize(identityStatement) }
            if let sampleStatement { sqlite3_finalize(sampleStatement) }
            return
        }
        defer {
            sqlite3_finalize(identityStatement)
            sqlite3_finalize(sampleStatement)
        }

        for bucket in buckets {
            for (appID, sample) in bucket.apps {
                sqlite3_reset(identityStatement)
                sqlite3_clear_bindings(identityStatement)
                bind(appID, to: identityStatement, column: 1)
                bind(sample.identity.displayName, to: identityStatement, column: 2)
                bind(sample.identity.bundleIdentifier, to: identityStatement, column: 3)
                bind(sample.identity.bundlePath, to: identityStatement, column: 4)
                bind(sample.identity.executablePath, to: identityStatement, column: 5)
                bind(sample.identity.kind.rawValue, to: identityStatement, column: 6)
                guard sqlite3_step(identityStatement) == SQLITE_DONE else { continue }

                sqlite3_reset(sampleStatement)
                sqlite3_clear_bindings(sampleStatement)
                bind(bucket.queryKey, to: sampleStatement, column: 1)
                sqlite3_bind_double(sampleStatement, 2, bucket.timestamp.timeIntervalSince1970)
                bind(appID, to: sampleStatement, column: 3)
                sqlite3_bind_int64(sampleStatement, 4, sample.downloadedBytes)
                sqlite3_bind_int64(sampleStatement, 5, sample.uploadedBytes)
                _ = sqlite3_step(sampleStatement)
            }
        }
    }

    private func migrateLegacyHistoryIfNeeded(_ database: OpaquePointer) {
        guard metadataValue("legacy_json_imported", database: database) == nil else { return }
        if let legacyFileURL,
           let data = try? Data(contentsOf: legacyFileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let buckets = try? decoder.decode([NetworkTrafficHistoryBucket].self, from: data) {
                execute(database, "BEGIN IMMEDIATE TRANSACTION")
                write(buckets.filter { $0.timestamp >= cutoffDate() }, to: database)
                execute(database, "COMMIT")
            }
        }
        setMetadataValue("1", for: "legacy_json_imported", database: database)
    }

    private func pruneExpiredRows(_ database: OpaquePointer) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "DELETE FROM traffic_samples WHERE bucket_timestamp < ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoffDate().timeIntervalSince1970)
        _ = sqlite3_step(statement)
        execute(database, "DELETE FROM app_identities WHERE id NOT IN (SELECT DISTINCT app_id FROM traffic_samples)")
    }

    private func cutoffDate() -> Date {
        now().addingTimeInterval(-retentionInterval)
    }

    private func metadataValue(_ key: String, database: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM traffic_metadata WHERE key = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, column: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, column: 0)
    }

    private func setMetadataValue(_ value: String, for key: String, database: OpaquePointer) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT OR REPLACE INTO traffic_metadata(key, value) VALUES (?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, column: 1)
        bind(value, to: statement, column: 2)
        _ = sqlite3_step(statement)
    }

    private func execute(_ database: OpaquePointer, _ sql: String) {
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func bind(_ value: String?, to statement: OpaquePointer, column: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, column)
            return
        }
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, column, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column: column)
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("MenuTools", isDirectory: true)
            .appendingPathComponent("network-traffic-history.sqlite3")
    }

    private static func legacyFileURL() -> URL {
        defaultFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("network-traffic-history.json")
    }
}

enum NetworkTrafficMath {
    static func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}

enum NetworkTrafficParser {
    /// 解析 `nettop -P -L 1 -x -n -J bytes_in,bytes_out` 的 CSV 输出。
    static func reading(from output: String, timestamp: TimeInterval) -> NetworkTrafficReading {
        let lines = output.split(whereSeparator: \.isNewline)
        let headerFound = lines.contains { line in
            let fields = csvFields(String(line)).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            return fields.contains("bytes_in") && fields.contains("bytes_out")
        }
        var apps: [NetworkAppTrafficReading] = []
        var connections: [NetworkConnectionTrafficReading] = []
        var currentProcess: NetworkAppTrafficReading?
        for line in lines {
            let fields = csvFields(String(line))
            if let process = parseRow(fields) {
                apps.append(process)
                currentProcess = process
            } else if let connection = parseConnection(fields, process: currentProcess) {
                connections.append(connection)
            }
        }
        return NetworkTrafficReading(
            timestamp: timestamp,
            apps: apps,
            connections: connections,
            status: headerFound ? .available : .malformedOutput
        )
    }

    private static func parseRow(_ fields: [String]) -> NetworkAppTrafficReading? {
        guard fields.count >= 3 else { return nil }
        let processField = fields[0].trimmingCharacters(in: .whitespaces)
        guard !processField.isEmpty,
              processField != "time",
              let process = processIdentifier(from: processField),
              let receivedBytes = Int64(fields[1].trimmingCharacters(in: .whitespaces)),
              let sentBytes = Int64(fields[2].trimmingCharacters(in: .whitespaces)),
              receivedBytes >= 0,
              sentBytes >= 0 else { return nil }
        return NetworkAppTrafficReading(
            appName: process.name,
            pid: process.pid,
            receivedBytes: receivedBytes,
            sentBytes: sentBytes
        )
    }

    private static func parseConnection(
        _ fields: [String],
        process: NetworkAppTrafficReading?
    ) -> NetworkConnectionTrafficReading? {
        guard fields.count >= 3,
              let process,
              let separator = fields[0].firstIndex(of: " "),
              let transport = transport(from: String(fields[0][..<separator])),
              let receivedBytes = Int64(fields[1].trimmingCharacters(in: .whitespaces)),
              let sentBytes = Int64(fields[2].trimmingCharacters(in: .whitespaces)),
              receivedBytes >= 0,
              sentBytes >= 0 else { return nil }
        return NetworkConnectionTrafficReading(
            identity: process.identity,
            pid: process.pid,
            transport: transport,
            endpoint: String(fields[0][fields[0].index(after: separator)...]),
            receivedBytes: receivedBytes,
            sentBytes: sentBytes
        )
    }

    private static func transport(from value: String) -> NetworkTrafficTransport? {
        if value.hasPrefix("tcp") { return .tcp }
        if value.hasPrefix("udp") { return .udp }
        return nil
    }

    private static func processIdentifier(from value: String) -> (name: String, pid: Int32)? {
        guard let separator = value.lastIndex(of: "."),
              let pid = Int32(value[value.index(after: separator)...]),
              pid > 0 else { return nil }
        let name = String(value[..<separator]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (name, pid)
    }

    private static func csvFields(_ line: String) -> [String] {
        let characters = Array(line)
        var fields: [String] = []
        var value = ""
        var isQuoted = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if isQuoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        value.append("\"")
                        index += 2
                        continue
                    }
                    isQuoted = false
                } else {
                    value.append(character)
                }
            } else if character == "\"" && value.isEmpty {
                isQuoted = true
            } else if character == "," {
                fields.append(value)
                value = ""
            } else {
                value.append(character)
            }
            index += 1
        }
        fields.append(value)
        return fields
    }
}

enum NetworkTrafficCalculator {
    private struct ProcessCounter {
        var identity: NetworkAppIdentity
        var receivedBytes: Int64
        var sentBytes: Int64
    }

    private struct AppAccumulator {
        var identity: NetworkAppIdentity
        var receivedBytes = Int64(0)
        var sentBytes = Int64(0)
        var processes: [NetworkProcessTrafficSnapshot] = []
    }

    static func calculate(
        current: NetworkTrafficReading,
        previous: NetworkTrafficReading?,
        sessionTotals: [String: NetworkTrafficSessionTotal],
        knownIdentities: [String: NetworkAppIdentity] = [:]
    ) -> NetworkTrafficCalculationResult {
        let currentByPID = aggregateByPID(current.apps)
        let previousByPID = aggregateByPID(previous?.apps ?? [])
        let elapsed = previous.map { max(current.timestamp - $0.timestamp, 0.001) }
        var accumulators: [String: AppAccumulator] = [:]
        var deltas: [NetworkTrafficDelta] = []

        for (pid, counter) in currentByPID {
            let previousCounter = previousByPID[pid]
            let hasSameIdentity = previousCounter?.identity.id == counter.identity.id
            let receivedDelta = delta(
                counter.receivedBytes,
                hasSameIdentity ? previousCounter?.receivedBytes : nil
            )
            let sentDelta = delta(
                counter.sentBytes,
                hasSameIdentity ? previousCounter?.sentBytes : nil
            )
            var accumulator = accumulators[counter.identity.id] ?? AppAccumulator(identity: counter.identity)
            accumulator.receivedBytes = NetworkTrafficMath.clampedAdd(accumulator.receivedBytes, receivedDelta)
            accumulator.sentBytes = NetworkTrafficMath.clampedAdd(accumulator.sentBytes, sentDelta)
            accumulator.processes.append(
                NetworkProcessTrafficSnapshot(
                    pid: pid,
                    processName: counter.identity.displayName,
                    downloadBytesPerSecond: rate(receivedDelta, elapsed),
                    uploadBytesPerSecond: rate(sentDelta, elapsed),
                    currentDownloadedBytes: receivedDelta,
                    currentUploadedBytes: sentDelta
                )
            )
            accumulators[counter.identity.id] = accumulator
        }

        var nextSessionTotals = sessionTotals
        var apps: [NetworkAppTrafficSnapshot] = []
        let allIDs = Set(accumulators.keys)
            .union(sessionTotals.keys)
            .union(knownIdentities.keys)

        for id in allIDs {
            guard let accumulator = accumulators[id] ?? knownIdentities[id].map({
                AppAccumulator(identity: $0)
            }) else { continue }
            // 兼容早期按显示名称保存的内存/测试数据，新的数据始终使用 canonical id。
            let storageKey = sessionTotals[id] != nil
                ? id
                : (sessionTotals[accumulator.identity.displayName] != nil
                    ? accumulator.identity.displayName
                    : id)
            let oldTotal = sessionTotals[storageKey] ?? NetworkTrafficSessionTotal(
                downloadedBytes: 0,
                uploadedBytes: 0
            )
            let total = NetworkTrafficSessionTotal(
                downloadedBytes: NetworkTrafficMath.clampedAdd(oldTotal.downloadedBytes, accumulator.receivedBytes),
                uploadedBytes: NetworkTrafficMath.clampedAdd(oldTotal.uploadedBytes, accumulator.sentBytes)
            )
            nextSessionTotals[storageKey] = total
            if accumulator.receivedBytes > 0 || accumulator.sentBytes > 0 {
                deltas.append(
                    NetworkTrafficDelta(
                        identity: accumulator.identity,
                        downloadedBytes: accumulator.receivedBytes,
                        uploadedBytes: accumulator.sentBytes
                    )
                )
            }
            apps.append(
                NetworkAppTrafficSnapshot(
                    identity: accumulator.identity,
                    downloadBytesPerSecond: rate(accumulator.receivedBytes, elapsed),
                    uploadBytesPerSecond: rate(accumulator.sentBytes, elapsed),
                    sessionDownloadedBytes: total.downloadedBytes,
                    sessionUploadedBytes: total.uploadedBytes,
                    processes: accumulator.processes.sorted { $0.pid < $1.pid },
                    isHistoricalOnly: accumulators[id] == nil
                )
            )
        }

        apps.sort {
            if $0.currentBytesPerSecond == $1.currentBytesPerSecond {
                let leftTotal = NetworkTrafficMath.clampedAdd(
                    $0.sessionDownloadedBytes,
                    $0.sessionUploadedBytes
                )
                let rightTotal = NetworkTrafficMath.clampedAdd(
                    $1.sessionDownloadedBytes,
                    $1.sessionUploadedBytes
                )
                if leftTotal == rightTotal {
                    return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
                }
                return leftTotal > rightTotal
            }
            return $0.currentBytesPerSecond > $1.currentBytesPerSecond
        }

        return NetworkTrafficCalculationResult(
            apps: apps,
            sessionTotals: nextSessionTotals,
            deltas: deltas
        )
    }

    private static func aggregateByPID(
        _ readings: [NetworkAppTrafficReading]
    ) -> [Int32: ProcessCounter] {
        readings.reduce(into: [:]) { result, reading in
            var current = result[reading.pid] ?? ProcessCounter(
                identity: reading.identity,
                receivedBytes: 0,
                sentBytes: 0
            )
            current.identity = reading.identity
            current.receivedBytes = NetworkTrafficMath.clampedAdd(
                current.receivedBytes,
                max(reading.receivedBytes, 0)
            )
            current.sentBytes = NetworkTrafficMath.clampedAdd(
                current.sentBytes,
                max(reading.sentBytes, 0)
            )
            result[reading.pid] = current
        }
    }

    private static func delta(_ current: Int64, _ previous: Int64?) -> Int64 {
        guard let previous, current >= previous else { return 0 }
        return current - previous
    }

    private static func rate(_ bytes: Int64, _ seconds: TimeInterval?) -> Int64 {
        guard let seconds, bytes > 0 else { return 0 }
        let value = Double(bytes) / seconds
        return value >= Double(Int64.max) ? Int64.max : Int64(value)
    }
}

protocol NetworkTrafficProviding: Sendable {
    func read(query: NetworkTrafficQuery) async -> NetworkTrafficReading
    func read(query: NetworkTrafficQuery, includeConnections: Bool) async -> NetworkTrafficReading
}

extension NetworkTrafficProviding {
    func read(query: NetworkTrafficQuery, includeConnections: Bool) async -> NetworkTrafficReading {
        await read(query: query)
    }
}

protocol NetworkProcessIdentityProviding: Sendable {
    func identity(for pid: Int32, fallback: String) -> NetworkAppIdentity
}

final class DefaultNetworkProcessIdentityProvider: NetworkProcessIdentityProviding, @unchecked Sendable {
    private struct CachedIdentity {
        let executablePath: String?
        let identity: NetworkAppIdentity
    }

    private let lock = NSLock()
    private var cache: [Int32: CachedIdentity] = [:]

    func identity(for pid: Int32, fallback: String) -> NetworkAppIdentity {
        let executablePath = executableURL(for: pid)?.path
        lock.lock()
        let cached = cache[pid]
        lock.unlock()
        if let cached, cached.executablePath == executablePath {
            return cached.identity
        }

        let application = NSRunningApplication(processIdentifier: pid)
        let candidateURL = application?.bundleURL ?? executablePath.map(URL.init(fileURLWithPath:))
        if let bundleURL = candidateURL.flatMap(outerAppBundle(for:)) {
            let bundle = Bundle(url: bundleURL)
            let bundleIdentifier = bundle?.bundleIdentifier
            let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? application?.localizedName
                ?? bundleURL.deletingPathExtension().lastPathComponent
            let key = bundleIdentifier.map { "bundle:\($0)" } ?? "path:\(bundleURL.path)"
            let identity = NetworkAppIdentity(
                id: key,
                displayName: displayName.isEmpty ? fallback : displayName,
                bundleIdentifier: bundleIdentifier,
                bundlePath: bundleURL.path,
                executablePath: executablePath,
                kind: .application
            )
            store(identity, executablePath: executablePath, for: pid)
            return identity
        }

        let executableName = executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let displayName = application?.localizedName ?? executableName ?? fallback
        let identity = NetworkAppIdentity(
            id: executablePath.map { "path:\($0)" } ?? "process:\(displayName)",
            displayName: displayName,
            bundleIdentifier: nil,
            bundlePath: nil,
            executablePath: executablePath,
            kind: .systemService
        )
        store(identity, executablePath: executablePath, for: pid)
        return identity
    }

    private func store(_ identity: NetworkAppIdentity, executablePath: String?, for pid: Int32) {
        guard executablePath != nil else { return }
        lock.lock()
        cache[pid] = CachedIdentity(executablePath: executablePath, identity: identity)
        lock.unlock()
    }

    private func executableURL(for pid: Int32) -> URL? {
        // PROC_PIDPATHINFO_MAXSIZE 是 C 宏，在 Swift 6 的 macOS SDK 中不可直接导入。
        var buffer = [CChar](repeating: 0, count: 4 * 1_024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    }

    private func outerAppBundle(for url: URL) -> URL? {
        var current = url
        var outermost: URL?
        while current.path != "/" {
            if current.pathExtension == "app" {
                outermost = current
            }
            current.deleteLastPathComponent()
        }
        return outermost
    }
}

struct NetworkTrafficProcessResult: Equatable, Sendable {
    let started: Bool
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
}

struct NetworkTrafficProcessRunner: Sendable {
    private final class PipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ value: Data) {
            guard !value.isEmpty else { return }
            lock.lock()
            data.append(value)
            lock.unlock()
        }

        func string() -> String {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return String(data: snapshot, encoding: .utf8) ?? ""
        }
    }

    let timeout: TimeInterval

    init(timeout: TimeInterval = 5) {
        self.timeout = max(timeout, 0.05)
    }

    func run(executableURL: URL, arguments: [String]) async -> NetworkTrafficProcessResult {
        let timeout = self.timeout
        let task = Task.detached {
            runSynchronously(executableURL: executableURL, arguments: arguments, timeout: timeout)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func runSynchronously(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> NetworkTrafficProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputCollector = PipeCollector()
        let errorCollector = PipeCollector()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            outputCollector.append(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errorCollector.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return NetworkTrafficProcessResult(
                started: false,
                terminationStatus: -1,
                standardOutput: "",
                standardError: error.localizedDescription,
                timedOut: false
            )
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var timedOut = false
        while process.isRunning {
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if timedOut {
            let terminationDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputCollector.append(outputPipe.fileHandleForReading.availableData)
        errorCollector.append(errorPipe.fileHandleForReading.availableData)
        return NetworkTrafficProcessResult(
            started: true,
            terminationStatus: process.terminationStatus,
            standardOutput: outputCollector.string(),
            standardError: errorCollector.string(),
            timedOut: timedOut
        )
    }
}

struct DefaultNetworkTrafficProvider: NetworkTrafficProviding {
    private let processIdentityProvider: any NetworkProcessIdentityProviding
    private let processRunner: NetworkTrafficProcessRunner

    init(
        processIdentityProvider: any NetworkProcessIdentityProviding = DefaultNetworkProcessIdentityProvider(),
        processRunner: NetworkTrafficProcessRunner = NetworkTrafficProcessRunner()
    ) {
        self.processIdentityProvider = processIdentityProvider
        self.processRunner = processRunner
    }

    func read(query: NetworkTrafficQuery) async -> NetworkTrafficReading {
        await read(query: query, includeConnections: false)
    }

    func read(query: NetworkTrafficQuery, includeConnections: Bool) async -> NetworkTrafficReading {
        await readFromProcess(query: query, includeConnections: includeConnections)
    }

    private func readFromProcess(
        query: NetworkTrafficQuery,
        includeConnections: Bool
    ) async -> NetworkTrafficReading {
        var arguments = query.commandArguments
        if includeConnections, let index = arguments.firstIndex(of: "-P") {
            arguments.remove(at: index)
        }
        let result = await processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/nettop"),
            arguments: arguments
        )
        guard result.started else {
            return NetworkTrafficReading(
                timestamp: ProcessInfo.processInfo.systemUptime,
                apps: [],
                status: .commandUnavailable
            )
        }
        guard !result.timedOut else {
            return NetworkTrafficReading(
                timestamp: ProcessInfo.processInfo.systemUptime,
                apps: [],
                status: .timedOut
            )
        }
        guard result.terminationStatus == 0 else {
            let errorText = result.standardError.lowercased()
            return NetworkTrafficReading(
                timestamp: ProcessInfo.processInfo.systemUptime,
                apps: [],
                status: errorText.contains("permission") || errorText.contains("not permitted")
                    ? .permissionDenied
                    : .commandFailed
            )
        }
        let parsed = NetworkTrafficParser.reading(
            from: result.standardOutput,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        let apps = parsed.apps.map { reading in
            NetworkAppTrafficReading(
                identity: processIdentityProvider.identity(for: reading.pid, fallback: reading.appName),
                pid: reading.pid,
                receivedBytes: reading.receivedBytes,
                sentBytes: reading.sentBytes
            )
        }
        let identitiesByPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0.identity) })
        let connections = parsed.connections.map { connection in
            NetworkConnectionTrafficReading(
                identity: identitiesByPID[connection.pid]
                    ?? processIdentityProvider.identity(for: connection.pid, fallback: connection.identity.displayName),
                pid: connection.pid,
                transport: connection.transport,
                endpoint: connection.endpoint,
                receivedBytes: connection.receivedBytes,
                sentBytes: connection.sentBytes
            )
        }
        return NetworkTrafficReading(
            timestamp: parsed.timestamp,
            apps: apps,
            connections: connections,
            status: parsed.status
        )
    }

}

@MainActor
protocol NetworkTrafficAlerting {
    func requestPermission()
    func send(app: NetworkAppTrafficSnapshot, threshold: Int64)
    func sendQuota(stage: NetworkTrafficQuotaStage, usedBytes: Int64, quotaBytes: Int64)
}

@MainActor
final class UserNotificationNetworkTrafficAlerter: NetworkTrafficAlerting {
    private let center = UNUserNotificationCenter.current()

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(app: NetworkAppTrafficSnapshot, threshold: Int64) {
        let content = UNMutableNotificationContent()
        content.title = L("traffic.notification.title", app.appName)
        content.body = L(
            "traffic.notification.body",
            ByteCountFormatter.string(fromByteCount: app.currentBytesPerSecond, countStyle: .binary)
        )
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "network-traffic-\(app.id)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    func sendQuota(stage: NetworkTrafficQuotaStage, usedBytes: Int64, quotaBytes: Int64) {
        let content = UNMutableNotificationContent()
        content.title = L("traffic.quota.notification.title")
        content.body = L(
            stage == .full
                ? "traffic.quota.notification.full"
                : "traffic.quota.notification.eighty",
            ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .binary),
            ByteCountFormatter.string(fromByteCount: quotaBytes, countStyle: .binary)
        )
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "network-traffic-quota-\(stage.rawValue)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}

enum NetworkTrafficSettingsKey {
    static let query = "networkTraffic.query"
    static let alertThreshold = "networkTraffic.alertThreshold"
    static let menuBarDisplayMode = "networkTraffic.menuBarDisplayMode"
    static let monthlyQuota = "networkTraffic.monthlyQuota"
    static let quotaAlertPeriod = "networkTraffic.quotaAlertPeriod"
    static let quotaAlertStage = "networkTraffic.quotaAlertStage"
}

enum NetworkTrafficSamplingPolicy {
    static func interval(liveObserverCount: Int, alertEnabled: Bool) -> TimeInterval {
        if liveObserverCount > 0 { return 2 }
        if alertEnabled { return 10 }
        return 60
    }
}

/// 持续采样 nettop，并保存当前运行期间及最近 30 天的 App 流量。
@MainActor
@Observable
final class NetworkTrafficService {
    static let shared = NetworkTrafficService()

    private let provider: any NetworkTrafficProviding
    private let historyStore: any NetworkTrafficHistoryStoring
    private let userDefaults: UserDefaults
    private let alerter: any NetworkTrafficAlerting
    private let now: () -> Date
    private var previousReading: NetworkTrafficReading?
    private var sessionTotals: [String: NetworkTrafficSessionTotal] = [:]
    private var sessionTotalsByQuery: [String: [String: NetworkTrafficSessionTotal]] = [:]
    private var knownIdentities: [String: NetworkAppIdentity] = [:]
    private var historyBuckets: [NetworkTrafficHistoryBucket]
    private var dirtyHistoryBucketIDs: Set<String> = []
    private var timer: Timer?
    private var liveObserverCount = 0
    private var lastHistoryPersistence = Date.distantPast
    private var lastAlertDates: [String: Date] = [:]
    private var alertQualificationCounts: [String: Int] = [:]
    private var connectionRequestGeneration = 0
    private var loadingConnectionIDs: Set<String> = []
    private var loadedConnectionIDs: Set<String> = []
    private var connectionLoadErrors: [String: NetworkTrafficReadStatus] = [:]
    private var isSampling = false
    private(set) var isRunning = false
    private(set) var lastSampleDuration: TimeInterval?
    private(set) var consecutiveSampleFailures = 0
    private(set) var lastSuccessfulSampleAt: Date?

    private(set) var snapshot: NetworkTrafficSnapshot {
        didSet {
            NotificationCenter.default.post(name: .networkTrafficSnapshotDidChange, object: self)
        }
    }
    private(set) var query: NetworkTrafficQuery
    private(set) var isPaused = false

    init(
        provider: any NetworkTrafficProviding = DefaultNetworkTrafficProvider(),
        historyStore: any NetworkTrafficHistoryStoring = NetworkTrafficHistoryStore(),
        userDefaults: UserDefaults = .standard,
        alerter: any NetworkTrafficAlerting = UserNotificationNetworkTrafficAlerter(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.historyStore = historyStore
        self.userDefaults = userDefaults
        self.alerter = alerter
        self.now = now
        let initialQuery = Self.loadQuery(from: userDefaults)
        self.query = initialQuery
        self.historyBuckets = historyStore.load(queryKey: initialQuery.storageKey)
        self.snapshot = NetworkTrafficSnapshot(
            apps: [],
            status: .commandUnavailable,
            query: initialQuery,
            lastUpdated: nil,
            history: []
        )
        restoreHistoricalIdentities()
    }

    var alertThresholdBytesPerSecond: Int64 {
        get { max(Int64(userDefaults.integer(forKey: NetworkTrafficSettingsKey.alertThreshold)), 0) }
        set {
            userDefaults.set(newValue, forKey: NetworkTrafficSettingsKey.alertThreshold)
            alertQualificationCounts.removeAll()
            lastAlertDates.removeAll()
            if newValue > 0 { alerter.requestPermission() }
            scheduleTimer()
        }
    }

    var menuBarDisplayMode: NetworkTrafficMenuBarDisplayMode {
        get {
            userDefaults.string(forKey: NetworkTrafficSettingsKey.menuBarDisplayMode)
                .flatMap(NetworkTrafficMenuBarDisplayMode.init(rawValue:)) ?? .off
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: NetworkTrafficSettingsKey.menuBarDisplayMode)
            NotificationCenter.default.post(name: .networkTrafficSnapshotDidChange, object: self)
        }
    }

    var monthlyQuotaBytes: Int64 {
        get { max(Int64(userDefaults.integer(forKey: NetworkTrafficSettingsKey.monthlyQuota)), 0) }
        set {
            userDefaults.set(max(newValue, 0), forKey: NetworkTrafficSettingsKey.monthlyQuota)
            for interface in NetworkTrafficInterface.allCases {
                for transport in NetworkTrafficTransport.allCases {
                    let queryKey = NetworkTrafficQuery(interface: interface, transport: transport).storageKey
                    userDefaults.removeObject(forKey: "\(NetworkTrafficSettingsKey.quotaAlertPeriod).\(queryKey)")
                    userDefaults.removeObject(forKey: "\(NetworkTrafficSettingsKey.quotaAlertStage).\(queryKey)")
                }
            }
            if newValue > 0 { alerter.requestPermission() }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        historyBuckets = historyStore.load(queryKey: query.storageKey)
        restoreHistoricalIdentities()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        connectionRequestGeneration += 1
        loadingConnectionIDs.removeAll()
        loadedConnectionIDs.removeAll()
        connectionLoadErrors.removeAll()
        persistRecentHistory()
        isRunning = false
        previousReading = nil
        sessionTotals = [:]
        sessionTotalsByQuery = [:]
        knownIdentities = historicalIdentities()
        snapshot = NetworkTrafficSnapshot(
            apps: [],
            status: .commandUnavailable,
            query: query,
            lastUpdated: nil,
            history: currentHistory()
        )
    }

    func beginLiveView() {
        liveObserverCount += 1
        if !isRunning { start() }
        scheduleTimer()
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    func endLiveView() {
        liveObserverCount = max(liveObserverCount - 1, 0)
        scheduleTimer()
    }

    func togglePaused() {
        isPaused.toggle()
        if !isPaused {
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func setQuery(_ query: NetworkTrafficQuery) {
        guard self.query != query else { return }
        sessionTotalsByQuery[self.query.storageKey] = sessionTotals
        persistRecentHistory()
        self.query = query
        historyBuckets = historyStore.load(queryKey: query.storageKey)
        connectionRequestGeneration += 1
        loadingConnectionIDs.removeAll()
        loadedConnectionIDs.removeAll()
        connectionLoadErrors.removeAll()
        userDefaults.set(query.storageKey, forKey: NetworkTrafficSettingsKey.query)
        previousReading = nil
        sessionTotals = sessionTotalsByQuery[query.storageKey] ?? [:]
        knownIdentities = historicalIdentities(for: query.storageKey)
        snapshot = NetworkTrafficSnapshot(
            apps: [],
            status: .commandUnavailable,
            query: query,
            lastUpdated: nil,
            history: currentHistory()
        )
        if isRunning {
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func clearHistory() {
        historyBuckets.removeAll { $0.queryKey == query.storageKey }
        dirtyHistoryBucketIDs = Set(dirtyHistoryBucketIDs.filter {
            !$0.hasPrefix("\(query.storageKey):")
        })
        historyStore.clear(queryKey: query.storageKey)
        let activeIDs = Set(sessionTotals.keys)
        knownIdentities = knownIdentities.filter { activeIDs.contains($0.key) }
        let visibleApps = snapshot.apps.filter { !$0.isHistoricalOnly || activeIDs.contains($0.id) }
        snapshot = NetworkTrafficSnapshot(
            apps: visibleApps,
            status: snapshot.status,
            query: query,
            lastUpdated: snapshot.lastUpdated,
            history: []
        )
    }

    func isLoadingConnections(for appID: String) -> Bool {
        loadingConnectionIDs.contains(appID)
    }

    func hasLoadedConnections(for appID: String) -> Bool {
        loadedConnectionIDs.contains(appID)
    }

    func connectionLoadError(for appID: String) -> NetworkTrafficReadStatus? {
        connectionLoadErrors[appID]
    }

    func loadConnections(for appID: String) {
        guard !loadingConnectionIDs.contains(appID),
              snapshot.apps.contains(where: { $0.id == appID && !$0.isHistoricalOnly }) else { return }
        loadingConnectionIDs.insert(appID)
        connectionLoadErrors.removeValue(forKey: appID)
        let generation = connectionRequestGeneration
        let provider = self.provider
        let query = self.query
        Task.detached { [provider, query] in
            let reading = await provider.read(query: query, includeConnections: true)
            let connections = NetworkConnectionTrafficAggregator.snapshots(
                from: reading.connections.filter { $0.identity.id == appID }
            )
            await MainActor.run { [weak self] in
                guard let self, self.connectionRequestGeneration == generation else { return }
                self.loadingConnectionIDs.remove(appID)
                guard reading.isAvailable else {
                    self.loadedConnectionIDs.remove(appID)
                    self.connectionLoadErrors[appID] = reading.status
                    return
                }
                self.connectionLoadErrors.removeValue(forKey: appID)
                self.loadedConnectionIDs.insert(appID)
                let apps = self.snapshot.apps.map { app in
                    app.id == appID ? app.replacingConnections(connections) : app
                }
                self.snapshot = NetworkTrafficSnapshot(
                    apps: apps,
                    status: self.snapshot.status,
                    query: self.snapshot.query,
                    lastUpdated: self.snapshot.lastUpdated,
                    history: self.snapshot.history
                )
            }
        }
    }

    func refresh() async {
        guard !isPaused, !isSampling else { return }
        isSampling = true
        defer { isSampling = false }

        let provider = self.provider
        let query = self.query
        let startedAt = now()
        let current = await provider.read(query: query)
        lastSampleDuration = max(now().timeIntervalSince(startedAt), 0)
        guard query == self.query else { return }
        guard current.isAvailable else {
            consecutiveSampleFailures += 1
            snapshot = NetworkTrafficSnapshot(
                apps: snapshot.apps,
                status: current.status,
                query: query,
                lastUpdated: snapshot.lastUpdated,
                history: currentHistory()
            )
            return
        }

        consecutiveSampleFailures = 0
        lastSuccessfulSampleAt = now()

        let result = NetworkTrafficCalculator.calculate(
            current: current,
            previous: previousReading,
            sessionTotals: sessionTotals,
            knownIdentities: knownIdentities
        )
        result.apps.forEach { knownIdentities[$0.identity.id] = $0.identity }
        sessionTotals = result.sessionTotals
        sessionTotalsByQuery[query.storageKey] = result.sessionTotals
        previousReading = current
        appendHistory(result.deltas, timestamp: now())
        let previousConnections = Dictionary(uniqueKeysWithValues: snapshot.apps.map {
            ($0.id, $0.connections)
        })
        let apps = (result.apps.isEmpty ? snapshot.apps : result.apps).map { app in
            guard !app.isHistoricalOnly,
                  let connections = previousConnections[app.id] else { return app }
            return app.replacingConnections(connections)
        }
        snapshot = NetworkTrafficSnapshot(
            apps: apps,
            status: .available,
            query: query,
            lastUpdated: now(),
            history: currentHistory()
        )
        sendAlerts(for: result.apps)
        sendQuotaAlertIfNeeded()
    }

    private func scheduleTimer() {
        guard isRunning else { return }
        timer?.invalidate()
        let interval = NetworkTrafficSamplingPolicy.interval(
            liveObserverCount: liveObserverCount,
            alertEnabled: alertThresholdBytesPerSecond > 0
        )
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    private func appendHistory(_ deltas: [NetworkTrafficDelta], timestamp: Date) {
        guard !deltas.isEmpty else { return }
        let bucketDate = Date(timeIntervalSince1970: floor(timestamp.timeIntervalSince1970 / 60) * 60)
        if let index = historyBuckets.firstIndex(where: {
            $0.queryKey == query.storageKey && $0.timestamp == bucketDate
        }) {
            for delta in deltas {
                if var sample = historyBuckets[index].apps[delta.identity.id] {
                    sample.identity = delta.identity
                    sample.downloadedBytes = NetworkTrafficMath.clampedAdd(sample.downloadedBytes, delta.downloadedBytes)
                    sample.uploadedBytes = NetworkTrafficMath.clampedAdd(sample.uploadedBytes, delta.uploadedBytes)
                    historyBuckets[index].apps[delta.identity.id] = sample
                } else {
                    historyBuckets[index].apps[delta.identity.id] = NetworkTrafficHistoryAppSample(
                        identity: delta.identity,
                        downloadedBytes: delta.downloadedBytes,
                        uploadedBytes: delta.uploadedBytes
                    )
                }
            }
        } else {
            historyBuckets.append(
                NetworkTrafficHistoryBucket(
                    timestamp: bucketDate,
                    queryKey: query.storageKey,
                    apps: Dictionary(uniqueKeysWithValues: deltas.map {
                        ($0.identity.id, NetworkTrafficHistoryAppSample(
                            identity: $0.identity,
                            downloadedBytes: $0.downloadedBytes,
                            uploadedBytes: $0.uploadedBytes
                        ))
                    })
                )
            )
        }
        if let bucket = historyBuckets.first(where: {
            $0.queryKey == query.storageKey && $0.timestamp == bucketDate
        }) {
            dirtyHistoryBucketIDs.insert(bucket.id)
        }
        historyBuckets.sort { $0.timestamp < $1.timestamp }
        let cutoff = timestamp.addingTimeInterval(-30 * 24 * 60 * 60)
        historyBuckets.removeAll { $0.timestamp < cutoff }
        if timestamp.timeIntervalSince(lastHistoryPersistence) >= 5 * 60 {
            persistRecentHistory()
            historyBuckets = historyStore.load(queryKey: query.storageKey)
            lastHistoryPersistence = timestamp
        }
    }

    private func currentHistory() -> [NetworkTrafficHistoryBucket] {
        historyBuckets.filter { $0.queryKey == query.storageKey }.sorted { $0.timestamp < $1.timestamp }
    }

    private func persistRecentHistory() {
        guard !dirtyHistoryBucketIDs.isEmpty else { return }
        let dirtyBuckets = historyBuckets.filter { dirtyHistoryBucketIDs.contains($0.id) }
        guard !dirtyBuckets.isEmpty else {
            dirtyHistoryBucketIDs.removeAll()
            return
        }
        historyStore.save(dirtyBuckets)
        dirtyHistoryBucketIDs.subtract(dirtyBuckets.map(\.id))
    }

    private func historicalIdentities(for queryKey: String? = nil) -> [String: NetworkAppIdentity] {
        let key = queryKey ?? query.storageKey
        return historyBuckets
            .filter { $0.queryKey == key }
            .flatMap(\.apps.values)
            .reduce(into: [:]) { $0[$1.identity.id] = $1.identity }
    }

    private func restoreHistoricalIdentities() {
        knownIdentities = historicalIdentities()
    }

    private func sendAlerts(for apps: [NetworkAppTrafficSnapshot]) {
        let threshold = alertThresholdBytesPerSecond
        guard threshold > 0 else { return }
        let now = now()
        let rearmThreshold = max(Int64(Double(threshold) * 0.8), 1)
        for app in apps {
            if app.currentBytesPerSecond >= threshold {
                alertQualificationCounts[app.id] = min(
                    (alertQualificationCounts[app.id] ?? 0) + 1,
                    2
                )
                guard alertQualificationCounts[app.id] == 2 else { continue }
                if let lastAlert = lastAlertDates[app.id], now.timeIntervalSince(lastAlert) < 300 {
                    continue
                }
                lastAlertDates[app.id] = now
                alerter.send(app: app, threshold: threshold)
            } else if app.currentBytesPerSecond < rearmThreshold {
                alertQualificationCounts.removeValue(forKey: app.id)
            }
        }
    }

    private func sendQuotaAlertIfNeeded() {
        let quota = monthlyQuotaBytes
        guard quota > 0 else { return }
        let period = monthIdentifier(for: now())
        let periodKey = "\(NetworkTrafficSettingsKey.quotaAlertPeriod).\(query.storageKey)"
        let stageKey = "\(NetworkTrafficSettingsKey.quotaAlertStage).\(query.storageKey)"
        let storedPeriod = userDefaults.string(forKey: periodKey)
        let storedStage = storedPeriod == period
            ? NetworkTrafficQuotaStage(rawValue: userDefaults.integer(forKey: stageKey)) ?? .none
            : .none
        let summary = NetworkTrafficPeriodSummary.make(
            from: historyBuckets,
            period: .month,
            queryKey: query.storageKey,
            now: now()
        )
        let nextStage = NetworkTrafficQuotaPolicy.stage(
            usedBytes: summary.totalBytes,
            quotaBytes: quota
        )
        guard nextStage > storedStage else { return }
        userDefaults.set(period, forKey: periodKey)
        userDefaults.set(nextStage.rawValue, forKey: stageKey)
        alerter.sendQuota(stage: nextStage, usedBytes: summary.totalBytes, quotaBytes: quota)
    }

    private func monthIdentifier(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private static func loadQuery(from defaults: UserDefaults) -> NetworkTrafficQuery {
        defaults.string(forKey: NetworkTrafficSettingsKey.query)
            .flatMap(NetworkTrafficQuery.init(storageKey:)) ?? .default
    }
}

extension Notification.Name {
    static let networkTrafficSnapshotDidChange = Notification.Name("MenuTools.networkTrafficSnapshotDidChange")
}

struct NetworkTrafficSnapshot: Codable, Equatable, Sendable {
    let apps: [NetworkAppTrafficSnapshot]
    let status: NetworkTrafficReadStatus
    let query: NetworkTrafficQuery
    let lastUpdated: Date?
    let history: [NetworkTrafficHistoryBucket]

    var isAvailable: Bool { status == .available }

    static let empty = NetworkTrafficSnapshot(
        apps: [],
        status: .commandUnavailable,
        query: .default,
        lastUpdated: nil,
        history: []
    )
}

enum NetworkTrafficExportSelection {
    static func make(
        snapshot: NetworkTrafficSnapshot,
        appIDs: Set<String>,
        range: NetworkTrafficHistoryRange,
        now: Date
    ) -> NetworkTrafficSnapshot {
        let start = now.addingTimeInterval(-range.interval * Double(range.pointCount))
        let history = snapshot.history.compactMap { bucket -> NetworkTrafficHistoryBucket? in
            guard bucket.timestamp >= start, bucket.timestamp <= now else { return nil }
            let apps = bucket.apps.filter { appIDs.contains($0.key) }
            guard !apps.isEmpty else { return nil }
            return NetworkTrafficHistoryBucket(
                timestamp: bucket.timestamp,
                queryKey: bucket.queryKey,
                apps: apps
            )
        }
        return NetworkTrafficSnapshot(
            apps: snapshot.apps.filter { appIDs.contains($0.id) },
            status: snapshot.status,
            query: snapshot.query,
            lastUpdated: snapshot.lastUpdated,
            history: history
        )
    }
}

enum NetworkTrafficExporter {
    static func csv(_ snapshot: NetworkTrafficSnapshot) -> String {
        var lines = [
            "app,kind,bundle_id,pid,transport,endpoint,download_bytes_per_second,upload_bytes_per_second,session_downloaded_bytes,session_uploaded_bytes,process"
        ]
        for app in snapshot.apps {
            if app.processes.isEmpty && app.connections.isEmpty {
                lines.append(csvLine(
                    app: app,
                    processName: "",
                    pid: nil,
                    transport: nil,
                    endpoint: nil,
                    downloadRate: app.downloadBytesPerSecond,
                    uploadRate: app.uploadBytesPerSecond
                ))
            } else {
                for process in app.processes {
                    lines.append(csvLine(
                        app: app,
                        processName: process.processName,
                        pid: process.pid,
                        transport: nil,
                        endpoint: nil,
                        downloadRate: process.downloadBytesPerSecond,
                        uploadRate: process.uploadBytesPerSecond
                    ))
                }
                for connection in app.connections {
                    lines.append(csvLine(
                        app: app,
                        processName: "",
                        pid: nil,
                        transport: connection.transport.rawValue,
                        endpoint: connection.endpoint,
                        downloadRate: 0,
                        uploadRate: 0
                    ))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func json(_ snapshot: NetworkTrafficSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func historyCSV(_ snapshot: NetworkTrafficSnapshot) -> String {
        var lines = [
            "timestamp,query,app,kind,bundle_id,downloaded_bytes,uploaded_bytes,total_bytes"
        ]
        let formatter = ISO8601DateFormatter()
        for bucket in snapshot.history.sorted(by: { $0.timestamp < $1.timestamp }) {
            for sample in bucket.apps.values.sorted(by: {
                $0.identity.displayName.localizedCaseInsensitiveCompare($1.identity.displayName)
                    == .orderedAscending
            }) {
                let total = NetworkTrafficMath.clampedAdd(
                    sample.downloadedBytes,
                    sample.uploadedBytes
                )
                lines.append([
                    escape(formatter.string(from: bucket.timestamp)),
                    escape(bucket.queryKey),
                    escape(sample.identity.displayName),
                    escape(sample.identity.kind.rawValue),
                    escape(sample.identity.bundleIdentifier ?? ""),
                    String(sample.downloadedBytes),
                    String(sample.uploadedBytes),
                    String(total)
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvLine(
        app: NetworkAppTrafficSnapshot,
        processName: String,
        pid: Int32?,
        transport: String?,
        endpoint: String?,
        downloadRate: Int64,
        uploadRate: Int64
    ) -> String {
        [
            escape(app.appName),
            escape(app.identity.kind.rawValue),
            escape(app.identity.bundleIdentifier ?? ""),
            pid.map(String.init) ?? "",
            escape(transport ?? ""),
            escape(endpoint ?? ""),
            String(downloadRate),
            String(uploadRate),
            String(app.sessionDownloadedBytes),
            String(app.sessionUploadedBytes),
            escape(processName)
        ].joined(separator: ",")
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
