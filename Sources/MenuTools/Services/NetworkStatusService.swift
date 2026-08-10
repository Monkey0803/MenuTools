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
}

@MainActor
@Observable
final class NetworkStatusService {
    private let provider: any NetworkStatusProviding
    private let probe: any NetworkProbe

    private(set) var snapshot = NetworkStatusSnapshot.empty
    private(set) var isPublicIPLoading = false
    private(set) var isLatencyTesting = false

    init(
        provider: any NetworkStatusProviding = DefaultNetworkStatusProvider(),
        probe: any NetworkProbe = URLSessionNetworkProbe()
    ) {
        self.provider = provider
        self.probe = probe
    }

    func refresh() {
        snapshot = NetworkStatusParser.refreshedSnapshot(
            from: provider.read(),
            preserving: snapshot
        )
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
            guard let latency = try? await probe.latencyMilliseconds() else { return }
            snapshot.latencyMilliseconds = latency
        }
    }
}
