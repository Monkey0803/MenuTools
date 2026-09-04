import CoreWLAN
import Darwin
import Foundation
import Observation

struct NetworkIPv4Address: Equatable, Sendable {
    let interfaceName: String
    let address: String
    let isUp: Bool
}

struct NetworkStatusSnapshot: Equatable, Sendable {
    let isConnected: Bool
    let interfaceName: String?
    let wifiName: String?
    let localIPv4: String?
    let vpnConnected: Bool
    var publicIPv4: String?
    var latencyMilliseconds: Int?
    var jitterMilliseconds: Int? = nil
    var packetLossPercent: Double? = nil
    var dnsMilliseconds: Int? = nil

    static let empty = NetworkStatusSnapshot(
        isConnected: false,
        interfaceName: nil,
        wifiName: nil,
        localIPv4: nil,
        vpnConnected: false,
        publicIPv4: nil,
        latencyMilliseconds: nil
    )
}

struct NetworkQualityMetrics: Equatable, Sendable {
    let latencyMilliseconds: Int
    let jitterMilliseconds: Int
    let packetLossPercent: Double
    let dnsMilliseconds: Int
}

enum NetworkQualityCalculator {
    static func make(latencySamples: [Int?], dnsMilliseconds: Int) -> NetworkQualityMetrics {
        let successful = latencySamples.compactMap { $0 }
        let latency = successful.isEmpty ? 0 : successful.reduce(0, +) / successful.count
        let jitter: Int
        if successful.count < 2 {
            jitter = 0
        } else {
            let differences = zip(successful, successful.dropFirst()).map { abs($1 - $0) }
            jitter = differences.reduce(0, +) / differences.count
        }
        let loss = latencySamples.isEmpty
            ? 100
            : Double(latencySamples.count - successful.count) / Double(latencySamples.count) * 100
        return NetworkQualityMetrics(
            latencyMilliseconds: latency,
            jitterMilliseconds: jitter,
            packetLossPercent: loss,
            dnsMilliseconds: dnsMilliseconds
        )
    }
}

struct NetworkEnvironmentSignature: Equatable, Sendable {
    let isConnected: Bool
    let interfaceName: String?
    let wifiName: String?
    let vpnConnected: Bool

    init(snapshot: NetworkStatusSnapshot) {
        self.init(
            isConnected: snapshot.isConnected,
            interfaceName: snapshot.interfaceName,
            wifiName: snapshot.wifiName,
            vpnConnected: snapshot.vpnConnected
        )
    }

    init(isConnected: Bool, interfaceName: String?, wifiName: String?, vpnConnected: Bool) {
        self.isConnected = isConnected
        self.interfaceName = interfaceName
        self.wifiName = wifiName
        self.vpnConnected = vpnConnected
    }
}

struct NetworkStatusTransition: Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let previous: NetworkEnvironmentSignature
    let current: NetworkEnvironmentSignature

    init(
        id: UUID = UUID(),
        timestamp: Date,
        previous: NetworkEnvironmentSignature,
        current: NetworkEnvironmentSignature
    ) {
        self.id = id
        self.timestamp = timestamp
        self.previous = previous
        self.current = current
    }
}

enum NetworkStatusTransitionDetector {
    static func transition(
        from previous: NetworkEnvironmentSignature,
        to current: NetworkEnvironmentSignature,
        at timestamp: Date
    ) -> NetworkStatusTransition? {
        guard previous != current else { return nil }
        return NetworkStatusTransition(timestamp: timestamp, previous: previous, current: current)
    }
}

struct NetworkStatusReading: Equatable, Sendable {
    let addresses: [NetworkIPv4Address]
    let interfaceName: String?
    let wifiName: String?
    let vpnConnected: Bool
}

enum NetworkStatusParser {
    static func vpnConnected(from output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            line.localizedCaseInsensitiveContains("(Connected)")
        }
    }

    static func preferredIPv4(from addresses: [NetworkIPv4Address]) -> String? {
        let usable = addresses.filter {
            $0.isUp && !$0.interfaceName.hasPrefix("lo") && !$0.interfaceName.hasPrefix("utun")
        }
        return usable.sorted { lhs, rhs in
            let leftPriority = lhs.interfaceName.hasPrefix("en") ? 0 : 1
            let rightPriority = rhs.interfaceName.hasPrefix("en") ? 0 : 1
            return leftPriority == rightPriority
                ? lhs.interfaceName < rhs.interfaceName
                : leftPriority < rightPriority
        }.first?.address
    }

    static func publicAddress(from output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func snapshot(from reading: NetworkStatusReading) -> NetworkStatusSnapshot {
        NetworkStatusSnapshot(
            isConnected: preferredIPv4(from: reading.addresses) != nil,
            interfaceName: reading.interfaceName,
            wifiName: reading.wifiName,
            localIPv4: preferredIPv4(from: reading.addresses),
            vpnConnected: reading.vpnConnected,
            publicIPv4: nil,
            latencyMilliseconds: nil
        )
    }

    static func refreshedSnapshot(
        from reading: NetworkStatusReading,
        preserving previous: NetworkStatusSnapshot
    ) -> NetworkStatusSnapshot {
        var refreshed = snapshot(from: reading)
        refreshed.publicIPv4 = previous.publicIPv4
        refreshed.latencyMilliseconds = previous.latencyMilliseconds
        refreshed.jitterMilliseconds = previous.jitterMilliseconds
        refreshed.packetLossPercent = previous.packetLossPercent
        refreshed.dnsMilliseconds = previous.dnsMilliseconds
        return refreshed
    }
}

protocol NetworkStatusProviding: Sendable {
    func read() -> NetworkStatusReading
}

struct DefaultNetworkStatusProvider: NetworkStatusProviding {
    func read() -> NetworkStatusReading {
        let wifi = CWWiFiClient.shared().interface()
        let interfaceName = wifi?.interfaceName ?? activeInterfaceName()
        let vpnOutput = runProcess("/usr/sbin/scutil", ["--nc", "list"])
        return NetworkStatusReading(
            addresses: ipv4Addresses(),
            interfaceName: interfaceName,
            wifiName: wifi?.ssid(),
            vpnConnected: NetworkStatusParser.vpnConnected(from: vpnOutput)
        )
    }

    private func activeInterfaceName() -> String? {
        ipv4Addresses().first(where: { $0.isUp })?.interfaceName
    }

    private func ipv4Addresses() -> [NetworkIPv4Address] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return [] }
        defer { freeifaddrs(pointer) }

        var addresses: [NetworkIPv4Address] = []
        var current = pointer
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            let flags = interface.pointee.ifa_flags
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

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
            let hostBytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            addresses.append(NetworkIPv4Address(
                interfaceName: String(cString: interface.pointee.ifa_name),
                address: String(decoding: hostBytes, as: UTF8.self),
                isUp: (flags & UInt32(IFF_UP)) != 0
            ))
        }
        return addresses
    }

    private func runProcess(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        process.waitUntilExit()
        return String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }
}

protocol NetworkProbe: Sendable {
    func publicIPv4() async throws -> String
    func latencyMilliseconds() async throws -> Int
    func networkQuality() async -> NetworkQualityMetrics
}

struct URLSessionNetworkProbe: NetworkProbe {
    enum ProbeError: Error {
        case invalidResponse
        case emptyAddress
    }

    func publicIPv4() async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "https://api.ipify.org")!)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProbeError.invalidResponse
        }
        guard let output = String(data: data, encoding: .utf8),
              let address = NetworkStatusParser.publicAddress(from: output) else {
            throw ProbeError.emptyAddress
        }
        return address
    }

    func latencyMilliseconds() async throws -> Int {
        let start = Date()
        var request = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) else {
            throw ProbeError.invalidResponse
        }
        return max(Int((Date().timeIntervalSince(start) * 1_000).rounded()), 0)
    }

    func networkQuality() async -> NetworkQualityMetrics {
        async let dns = Self.dnsResolutionMilliseconds()
        var samples: [Int?] = []
        for _ in 0..<3 {
            samples.append(try? await latencyMilliseconds())
        }
        return await NetworkQualityCalculator.make(
            latencySamples: samples,
            dnsMilliseconds: dns
        )
    }

    private static func dnsResolutionMilliseconds() async -> Int {
        await Task.detached {
            let start = ProcessInfo.processInfo.systemUptime
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo("www.apple.com", nil, nil, &result)
            if let result { freeaddrinfo(result) }
            guard status == 0 else { return 0 }
            return max(Int(((ProcessInfo.processInfo.systemUptime - start) * 1_000).rounded()), 0)
        }.value
    }
}

@MainActor
@Observable
final class NetworkStatusService {
    static let shared = NetworkStatusService()

    private let provider: any NetworkStatusProviding
    private let probe: any NetworkProbe
    private let now: () -> Date
    private var previousEnvironment: NetworkEnvironmentSignature?
    private var monitorTimer: Timer?

    private(set) var snapshot = NetworkStatusSnapshot.empty
    private(set) var isPublicIPLoading = false
    private(set) var isLatencyTesting = false
    private(set) var recentTransitions: [NetworkStatusTransition] = []

    init(
        provider: any NetworkStatusProviding = DefaultNetworkStatusProvider(),
        probe: any NetworkProbe = URLSessionNetworkProbe(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.probe = probe
        self.now = now
    }

    func refresh() {
        let refreshed = NetworkStatusParser.refreshedSnapshot(
            from: provider.read(),
            preserving: snapshot
        )
        let currentEnvironment = NetworkEnvironmentSignature(snapshot: refreshed)
        if let previousEnvironment,
           let transition = NetworkStatusTransitionDetector.transition(
            from: previousEnvironment,
            to: currentEnvironment,
            at: now()
           ) {
            recentTransitions.append(transition)
            recentTransitions = Array(recentTransitions.suffix(20))
        }
        previousEnvironment = currentEnvironment
        snapshot = refreshed
    }

    func startMonitoring() {
        guard monitorTimer == nil else { return }
        refresh()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    func fetchPublicIP() {
        guard !isPublicIPLoading else { return }
        isPublicIPLoading = true
        let probe = self.probe
        Task {
            defer { isPublicIPLoading = false }
            guard let address = try? await probe.publicIPv4() else { return }
            snapshot.publicIPv4 = address
        }
    }

    func testLatency() {
        guard !isLatencyTesting else { return }
        isLatencyTesting = true
        let probe = self.probe
        Task {
            defer { isLatencyTesting = false }
            let quality = await probe.networkQuality()
            snapshot.latencyMilliseconds = quality.latencyMilliseconds
            snapshot.jitterMilliseconds = quality.jitterMilliseconds
            snapshot.packetLossPercent = quality.packetLossPercent
            snapshot.dnsMilliseconds = quality.dnsMilliseconds
        }
    }
}
