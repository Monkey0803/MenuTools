import Foundation
import Testing
@testable import MenuTools

@Test("网络状态解析出已连接 VPN")
func networkParserDetectsConnectedVPN() {
    let output = """
    Available network connection services in the current set (*=enabled):
    * (Connected)           Work VPN
      (Disconnected)        Old VPN
    """

    #expect(NetworkStatusParser.vpnConnected(from: output))
}

@Test("网络状态只选择非回环且可用的 IPv4")
func networkParserChoosesPreferredIPv4() {
    let addresses = [
        NetworkIPv4Address(interfaceName: "lo0", address: "127.0.0.1", isUp: true),
        NetworkIPv4Address(interfaceName: "en0", address: "192.168.1.8", isUp: true),
        NetworkIPv4Address(interfaceName: "utun0", address: "10.0.0.2", isUp: true)
    ]

    #expect(NetworkStatusParser.preferredIPv4(from: addresses) == "192.168.1.8")
}

@Test("网络探针地址解析会去掉空白")
func networkParserTrimsPublicAddress() {
    #expect(NetworkStatusParser.publicAddress(from: "  203.0.113.8\n") == "203.0.113.8")
    #expect(NetworkStatusParser.publicAddress(from: "") == nil)
}

@Test("网络状态刷新保留已获取的公网 IP 和延迟")
func networkParserRefreshPreservesProbes() {
    let previous = NetworkStatusSnapshot(
        isConnected: true,
        interfaceName: "en0",
        wifiName: "Office",
        localIPv4: "192.168.1.8",
        vpnConnected: false,
        publicIPv4: "203.0.113.8",
        latencyMilliseconds: 24
    )
    let reading = NetworkStatusReading(
        addresses: [NetworkIPv4Address(interfaceName: "en0", address: "192.168.1.9", isUp: true)],
        interfaceName: "en0",
        wifiName: "Office",
        vpnConnected: true
    )

    let refreshed = NetworkStatusParser.refreshedSnapshot(from: reading, preserving: previous)

    #expect(refreshed.localIPv4 == "192.168.1.9")
    #expect(refreshed.vpnConnected)
    #expect(refreshed.publicIPv4 == "203.0.113.8")
    #expect(refreshed.latencyMilliseconds == 24)
}

@Test("网络质量会计算平均延迟、抖动、丢包和 DNS")
func networkQualityCalculatorSummarizesSamples() {
    let quality = NetworkQualityCalculator.make(
        latencySamples: [20, nil, 30],
        dnsMilliseconds: 5
    )

    #expect(quality.latencyMilliseconds == 25)
    #expect(quality.jitterMilliseconds == 10)
    #expect(abs(quality.packetLossPercent - 33.333) < 0.01)
    #expect(quality.dnsMilliseconds == 5)
}

@Test("网络接口、WiFi 或 VPN 变化会生成切换记录")
func networkTransitionDetectorRecordsMeaningfulChanges() {
    let previous = NetworkEnvironmentSignature(
        isConnected: true,
        interfaceName: "en0",
        wifiName: "Office",
        vpnConnected: false
    )
    let current = NetworkEnvironmentSignature(
        isConnected: true,
        interfaceName: "en0",
        wifiName: "Home",
        vpnConnected: true
    )

    let event = NetworkStatusTransitionDetector.transition(
        from: previous,
        to: current,
        at: Date(timeIntervalSince1970: 100)
    )

    #expect(event?.previous == previous)
    #expect(event?.current == current)
    #expect(event?.timestamp == Date(timeIntervalSince1970: 100))
    #expect(NetworkStatusTransitionDetector.transition(from: current, to: current, at: Date()) == nil)
}
