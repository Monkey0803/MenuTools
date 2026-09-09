import Foundation
import Testing
@testable import MenuTools

@Test("nettop CSV 可以解析进程名、PID 和累计字节")
func trafficParserReadsProcessCounters() {
    let output = """
    ,bytes_in,bytes_out,
    \"Photo, Editor.42\",1200,800,
    WeChat.486,200,300,
    malformed,not-a-number,0,
    """

    let reading = NetworkTrafficParser.reading(from: output, timestamp: 10)

    #expect(reading.isAvailable)
    #expect(reading.apps == [
        NetworkAppTrafficReading(
            appName: "Photo, Editor",
            pid: 42,
            receivedBytes: 1_200,
            sentBytes: 800
        ),
        NetworkAppTrafficReading(
            appName: "WeChat",
            pid: 486,
            receivedBytes: 200,
            sentBytes: 300
        )
    ])
}

@Test("App 流量按名称聚合多个进程并按当前速率排序")
func trafficCalculatorGroupsProcessesByApp() {
    let previous = NetworkTrafficReading(
        timestamp: 10,
        apps: [
            .init(appName: "Lark", pid: 1, receivedBytes: 1_000, sentBytes: 2_000),
            .init(appName: "Lark", pid: 3, receivedBytes: 500, sentBytes: 1_000),
            .init(appName: "Safari", pid: 2, receivedBytes: 1_000, sentBytes: 1_000)
        ],
        isAvailable: true
    )
    let current = NetworkTrafficReading(
        timestamp: 12,
        apps: [
            .init(appName: "Lark", pid: 1, receivedBytes: 5_000, sentBytes: 2_500),
            .init(appName: "Lark", pid: 3, receivedBytes: 2_000, sentBytes: 3_500),
            .init(appName: "Safari", pid: 2, receivedBytes: 1_200, sentBytes: 1_200)
        ],
        isAvailable: true
    )

    let result = NetworkTrafficCalculator.calculate(
        current: current,
        previous: previous,
        sessionTotals: [:]
    )

    #expect(result.apps.map(\.appName) == ["Lark", "Safari"])
    #expect(result.apps[0].downloadBytesPerSecond == 2_750)
    #expect(result.apps[0].uploadBytesPerSecond == 1_500)
    #expect(result.apps[0].sessionDownloadedBytes == 5_500)
    #expect(result.apps[0].sessionUploadedBytes == 3_000)
    #expect(result.apps[1].downloadBytesPerSecond == 100)
}

@Test("App 流量采样会保留跨刷新会话累计")
func trafficCalculatorPreservesSessionTotals() {
    let previous = NetworkTrafficReading(
        timestamp: 10,
        apps: [.init(appName: "Safari", pid: 2, receivedBytes: 1_000, sentBytes: 500)],
        isAvailable: true
    )
    let current = NetworkTrafficReading(
        timestamp: 12,
        apps: [.init(appName: "Safari", pid: 2, receivedBytes: 1_400, sentBytes: 700)],
        isAvailable: true
    )

    let result = NetworkTrafficCalculator.calculate(
        current: current,
        previous: previous,
        sessionTotals: [
            "Safari": NetworkTrafficSessionTotal(downloadedBytes: 800, uploadedBytes: 100)
        ]
    )

    #expect(result.apps[0].sessionDownloadedBytes == 1_200)
    #expect(result.apps[0].sessionUploadedBytes == 300)
}

@Test("进程计数器回退时不会产生负流量")
func trafficCalculatorClampsProcessCounterReset() {
    let previous = NetworkTrafficReading(
        timestamp: 10,
        apps: [.init(appName: "Safari", pid: 2, receivedBytes: 5_000, sentBytes: 5_000)],
        isAvailable: true
    )
    let current = NetworkTrafficReading(
        timestamp: 12,
        apps: [.init(appName: "Safari", pid: 2, receivedBytes: 100, sentBytes: 200)],
        isAvailable: true
    )

    let result = NetworkTrafficCalculator.calculate(
        current: current,
        previous: previous,
        sessionTotals: [
            "Safari": NetworkTrafficSessionTotal(downloadedBytes: 800, uploadedBytes: 700)
        ]
    )

    #expect(result.apps[0].downloadBytesPerSecond == 0)
    #expect(result.apps[0].uploadBytesPerSecond == 0)
    #expect(result.apps[0].sessionDownloadedBytes == 800)
    #expect(result.apps[0].sessionUploadedBytes == 700)
}

@Test("PID 被新进程复用时不会把旧进程计数算给新 App")
func trafficCalculatorIgnoresReusedPIDBaseline() {
    let oldIdentity = NetworkAppIdentity.fallback(processName: "OldApp")
    let newIdentity = NetworkAppIdentity.fallback(processName: "NewApp")
    let previous = NetworkTrafficReading(
        timestamp: 10,
        apps: [.init(identity: oldIdentity, pid: 2, receivedBytes: 100, sentBytes: 50)],
        status: .available
    )
    let current = NetworkTrafficReading(
        timestamp: 12,
        apps: [.init(identity: newIdentity, pid: 2, receivedBytes: 500, sentBytes: 200)],
        status: .available
    )

    let result = NetworkTrafficCalculator.calculate(
        current: current,
        previous: previous,
        sessionTotals: [:]
    )

    #expect(result.apps.first?.id == newIdentity.id)
    #expect(result.apps.first?.currentBytesPerSecond == 0)
    #expect(result.apps.first?.sessionDownloadedBytes == 0)
}

@Test("不可用的 nettop 输出不会伪造 App 流量")
func trafficParserRejectsUnavailableOutput() {
    let reading = NetworkTrafficParser.reading(from: "", timestamp: 10)

    #expect(!reading.isAvailable)
    #expect(reading.apps.isEmpty)
}

@Test("网络流量模块出现在已启用功能设置中")
func networkTrafficModuleHasSettingsDestination() {
    #expect(SettingsTab.networkTraffic.pluginID == .networkTraffic)
    #expect(SettingsTab.enabledFeatureTabs(enabledPluginIDs: [.networkTraffic]) == [.networkTraffic])
}

@Test("网络流量搜索使用模块内搜索栏而非工具栏")
func networkTrafficSearchIsEmbeddedInModule() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = projectRoot
        .appendingPathComponent("Sources")
        .appendingPathComponent("MenuTools")
        .appendingPathComponent("NetworkTrafficSettingsView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("private var searchField: some View"))
    #expect(source.contains("private var appsContent: some View"))
    #expect(source.contains("searchField\n            queryControls"))
    #expect(!source.contains(".searchable(text: $searchText, placement: .toolbar"))
}

@Test("历史趋势只有一个时间桶时不会横向铺满")
func singleHistoryBucketUsesNarrowBar() {
    #expect(NetworkTrafficHistoryChartLayout.barWidth(totalWidth: 560, sampleCount: 1) == 8)
    #expect(NetworkTrafficHistoryChartLayout.barWidth(totalWidth: 560, sampleCount: 60) < 10)
    #expect(NetworkTrafficHistoryChartLayout.barWidth(totalWidth: 560, sampleCount: 0) == 0)
}

@Test("历史趋势悬停位置可以命中对应柱子并避开间隙")
func historyChartHoverMapsToBarIndex() {
    let width = NetworkTrafficHistoryChartLayout.barWidth(totalWidth: 100, sampleCount: 4)
    #expect(NetworkTrafficHistoryChartLayout.hoveredIndex(x: width / 2, totalWidth: 100, sampleCount: 4) == 0)
    #expect(NetworkTrafficHistoryChartLayout.hoveredIndex(x: width + 1.5, totalWidth: 100, sampleCount: 4) == nil)
    #expect(NetworkTrafficHistoryChartLayout.hoveredIndex(x: width + 3, totalWidth: 100, sampleCount: 4) == 1)
    #expect(NetworkTrafficHistoryChartLayout.hoveredIndex(x: 101, totalWidth: 100, sampleCount: 4) == nil)
}

@Test("App 迷你趋势的所有采样柱都位于画布边界内")
func networkTrafficMiniTrendFitsCanvas() {
    let size = CGSize(width: 50, height: 22)
    for count in [1, 60, 120] {
        let bars = NetworkTrafficMiniTrendLayout.barFrames(
            bytes: (0..<count).map { Int64($0) }, size: size
        )
        #expect(bars.count == count)
        for bar in bars {
            #expect(bar.minX >= 0 && bar.maxX <= size.width)
            #expect(bar.minY >= 0 && bar.maxY <= size.height)
        }
        for (left, right) in zip(bars, bars.dropFirst()) {
            #expect(left.maxX <= right.minX)
        }
    }
    #expect(NetworkTrafficMiniTrendLayout.barFrames(bytes: [], size: size).isEmpty)
    #expect(NetworkTrafficMiniTrendLayout.barFrames(bytes: [1], size: .zero).isEmpty)
}

@Test("历史趋势按真实时间补齐无流量空档")
func historySeriesFillsTimeGaps() {
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let queryKey = NetworkTrafficQuery.default.storageKey
    let buckets = [
        NetworkTrafficHistoryBucket(
            timestamp: Date(timeIntervalSince1970: 0),
            queryKey: queryKey,
            apps: [identity.id: NetworkTrafficHistoryAppSample(
                identity: identity,
                downloadedBytes: 10,
                uploadedBytes: 0
            )]
        ),
        NetworkTrafficHistoryBucket(
            timestamp: Date(timeIntervalSince1970: 60),
            queryKey: queryKey,
            apps: [identity.id: NetworkTrafficHistoryAppSample(
                identity: identity,
                downloadedBytes: 20,
                uploadedBytes: 0
            )]
        ),
        NetworkTrafficHistoryBucket(
            timestamp: Date(timeIntervalSince1970: 180),
            queryKey: queryKey,
            apps: [identity.id: NetworkTrafficHistoryAppSample(
                identity: identity,
                downloadedBytes: 40,
                uploadedBytes: 0
            )]
        )
    ]

    let points = NetworkTrafficHistorySeries.make(
        from: buckets,
        range: .hour,
        now: Date(timeIntervalSince1970: 180)
    )

    #expect(points.count == 60)
    #expect(points[56].bytes == 10)
    #expect(points[57].bytes == 20)
    #expect(points[58].bytes == 0)
    #expect(points[59].bytes == 40)
}

@Test("历史趋势可以只统计筛选后的 App")
func historySeriesFiltersApps() {
    let safari = NetworkAppIdentity.fallback(processName: "Safari")
    let mail = NetworkAppIdentity.fallback(processName: "Mail")
    let bucket = NetworkTrafficHistoryBucket(
        timestamp: Date(timeIntervalSince1970: 0),
        queryKey: NetworkTrafficQuery.default.storageKey,
        apps: [
            safari.id: NetworkTrafficHistoryAppSample(identity: safari, downloadedBytes: 100, uploadedBytes: 20),
            mail.id: NetworkTrafficHistoryAppSample(identity: mail, downloadedBytes: 900, uploadedBytes: 80)
        ]
    )

    let points = NetworkTrafficHistorySeries.make(
        from: [bucket],
        range: .hour,
        now: Date(timeIntervalSince1970: 0),
        appIDs: [safari.id]
    )

    #expect(points.last?.bytes == 120)
    #expect(points.last?.downloadedBytes == 100)
    #expect(points.last?.uploadedBytes == 20)
}

@Test("历史范围排名按总流量排序")
func networkTrafficHistoryRankingSortsAppsByBytes() {
    let safari = NetworkAppIdentity.fallback(processName: "Safari")
    let mail = NetworkAppIdentity.fallback(processName: "Mail")
    let bucket = NetworkTrafficHistoryBucket(
        timestamp: Date(timeIntervalSince1970: 0),
        queryKey: NetworkTrafficQuery.default.storageKey,
        apps: [
            safari.id: .init(identity: safari, downloadedBytes: 100, uploadedBytes: 20),
            mail.id: .init(identity: mail, downloadedBytes: 500, uploadedBytes: 80)
        ]
    )

    let ranking = NetworkTrafficHistoryRanking.make(
        from: [bucket],
        range: .hour,
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(ranking.map(\.identity.id) == [mail.id, safari.id])
    #expect(ranking.map(\.totalBytes) == [580, 120])
}

@Test("导出选择只保留当前 App 和时间范围")
func networkTrafficExportSelectionFiltersVisibleData() {
    let safari = NetworkAppIdentity.fallback(processName: "Safari")
    let mail = NetworkAppIdentity.fallback(processName: "Mail")
    let safariSnapshot = NetworkAppTrafficSnapshot(
        identity: safari,
        downloadBytesPerSecond: 100,
        uploadBytesPerSecond: 20,
        sessionDownloadedBytes: 1_000,
        sessionUploadedBytes: 200
    )
    let mailSnapshot = NetworkAppTrafficSnapshot(
        identity: mail,
        downloadBytesPerSecond: 500,
        uploadBytesPerSecond: 80,
        sessionDownloadedBytes: 5_000,
        sessionUploadedBytes: 800
    )
    let old = NetworkTrafficHistoryBucket(
        timestamp: Date(timeIntervalSince1970: -60),
        queryKey: NetworkTrafficQuery.default.storageKey,
        apps: [safari.id: .init(identity: safari, downloadedBytes: 10, uploadedBytes: 2)]
    )
    let recent = NetworkTrafficHistoryBucket(
        timestamp: Date(timeIntervalSince1970: 3_600),
        queryKey: NetworkTrafficQuery.default.storageKey,
        apps: [
            safari.id: .init(identity: safari, downloadedBytes: 20, uploadedBytes: 4),
            mail.id: .init(identity: mail, downloadedBytes: 50, uploadedBytes: 8)
        ]
    )
    let snapshot = NetworkTrafficSnapshot(
        apps: [safariSnapshot, mailSnapshot],
        status: .available,
        query: .default,
        lastUpdated: Date(timeIntervalSince1970: 3_600),
        history: [old, recent]
    )

    let filtered = NetworkTrafficExportSelection.make(
        snapshot: snapshot,
        appIDs: [safari.id],
        range: .hour,
        now: Date(timeIntervalSince1970: 3_600)
    )

    #expect(filtered.apps.map(\.id) == [safari.id])
    #expect(filtered.history.count == 1)
    #expect(Set(filtered.history[0].apps.keys) == [safari.id])
}

@Test("流量汇总会随搜索和筛选结果变化")
func trafficSummaryUsesVisibleApps() {
    let first = NetworkAppTrafficSnapshot(
        appName: "Safari",
        downloadBytesPerSecond: 100,
        uploadBytesPerSecond: 20,
        sessionDownloadedBytes: 1_000,
        sessionUploadedBytes: 200
    )
    let second = NetworkAppTrafficSnapshot(
        appName: "Mail",
        downloadBytesPerSecond: 900,
        uploadBytesPerSecond: 80,
        sessionDownloadedBytes: 9_000,
        sessionUploadedBytes: 800
    )

    #expect(NetworkTrafficSummary.make([first]).downloadBytesPerSecond == 100)
    #expect(NetworkTrafficSummary.make([first]).sessionDownloadedBytes == 1_000)
    #expect(NetworkTrafficSummary.make([first, second]).currentBytesPerSecond == 1_100)
}

@Test("历史趋势支持最近 30 天")
func historyRangeSupportsMonth() {
    #expect(NetworkTrafficHistoryRange.month.interval == 12 * 60 * 60)
    #expect(NetworkTrafficHistoryRange.month.pointCount == 60)
}

@Test("历史范围统计会计算总量、峰值和平均值")
func historyStatsSummarizeSelectedRange() {
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let queryKey = NetworkTrafficQuery.default.storageKey
    let buckets = [
        NetworkTrafficHistoryBucket(
            timestamp: Date(timeIntervalSince1970: 0),
            queryKey: queryKey,
            apps: [identity.id: NetworkTrafficHistoryAppSample(
                identity: identity,
                downloadedBytes: 100,
                uploadedBytes: 0
            )]
        ),
        NetworkTrafficHistoryBucket(
            timestamp: Date(timeIntervalSince1970: 60),
            queryKey: queryKey,
            apps: [identity.id: NetworkTrafficHistoryAppSample(
                identity: identity,
                downloadedBytes: 300,
                uploadedBytes: 0
            )]
        )
    ]

    let stats = NetworkTrafficHistoryStats.make(
        from: buckets,
        range: .hour,
        now: Date(timeIntervalSince1970: 60),
        appIDs: [identity.id]
    )

    #expect(stats.totalBytes == 400)
    #expect(stats.peakBytes == 300)
    #expect(stats.averageBytes == 6)
}

@Test("今日和本月统计按日历边界汇总上下行")
func trafficPeriodSummaryUsesCalendarBoundaries() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 9,
        day: 4,
        hour: 12
    )))
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    func bucket(day: Int, downloaded: Int64, uploaded: Int64) throws -> NetworkTrafficHistoryBucket {
        NetworkTrafficHistoryBucket(
            timestamp: try #require(calendar.date(from: DateComponents(
                year: 2026,
                month: 9,
                day: day,
                hour: 8
            ))),
            queryKey: NetworkTrafficQuery.default.storageKey,
            apps: [identity.id: .init(
                identity: identity,
                downloadedBytes: downloaded,
                uploadedBytes: uploaded
            )]
        )
    }
    let buckets = [
        try bucket(day: 3, downloaded: 100, uploaded: 20),
        try bucket(day: 4, downloaded: 300, uploaded: 40)
    ]

    let today = NetworkTrafficPeriodSummary.make(
        from: buckets,
        period: .today,
        now: now,
        calendar: calendar
    )
    let month = NetworkTrafficPeriodSummary.make(
        from: buckets,
        period: .month,
        now: now,
        calendar: calendar
    )

    #expect(today.downloadedBytes == 300)
    #expect(today.uploadedBytes == 40)
    #expect(month.totalBytes == 460)
}

@Test("月度额度提醒分为百分之八十和已用完")
func networkTrafficQuotaPolicyUsesMilestones() {
    #expect(NetworkTrafficQuotaPolicy.stage(usedBytes: 0, quotaBytes: 1_000) == .none)
    #expect(NetworkTrafficQuotaPolicy.stage(usedBytes: 799, quotaBytes: 1_000) == .none)
    #expect(NetworkTrafficQuotaPolicy.stage(usedBytes: 800, quotaBytes: 1_000) == .eightyPercent)
    #expect(NetworkTrafficQuotaPolicy.stage(usedBytes: 1_000, quotaBytes: 1_000) == .full)
    #expect(NetworkTrafficQuotaPolicy.stage(usedBytes: 10_000, quotaBytes: 0) == .none)
}

@Test("菜单栏网速支持总速率和上下行两种显示")
func networkTrafficMenuBarTitleSupportsDisplayModes() {
    let snapshot = NetworkTrafficSnapshot(
        apps: [
            .init(
                appName: "Safari",
                downloadBytesPerSecond: 1_572_864,
                uploadBytesPerSecond: 524_288,
                sessionDownloadedBytes: 0,
                sessionUploadedBytes: 0
            )
        ],
        status: .available,
        query: .default,
        lastUpdated: nil,
        history: []
    )

    #expect(NetworkTrafficMenuBarPresenter.title(snapshot: snapshot, mode: .off) == nil)
    #expect(NetworkTrafficMenuBarPresenter.title(snapshot: snapshot, mode: .total) == "↕ 2.0 MB/s")
    #expect(NetworkTrafficMenuBarPresenter.title(snapshot: snapshot, mode: .upDown) == "↓ 1.5 MB/s  ↑ 512 KB/s")
}

@Test("网卡信息会保留 IPv4、IPv6 并识别 VPN 接口")
func networkTrafficInterfaceInfoSummarizesAddresses() {
    let infos = NetworkTrafficInterfaceInspector.summarize([
        NetworkTrafficInterfaceAddress(interfaceName: "en0", address: "192.168.1.8", isIPv6: false, isUp: true),
        NetworkTrafficInterfaceAddress(interfaceName: "en0", address: "fe80::1", isIPv6: true, isUp: true),
        NetworkTrafficInterfaceAddress(interfaceName: "utun4", address: "10.8.0.2", isIPv6: false, isUp: true),
        NetworkTrafficInterfaceAddress(interfaceName: "lo0", address: "127.0.0.1", isIPv6: false, isUp: true)
    ])

    #expect(infos.count == 2)
    #expect(infos.first?.name == "en0")
    #expect(infos.first?.ipv4 == "192.168.1.8")
    #expect(infos.first?.ipv6 == "fe80::1")
    #expect(infos.contains { $0.name == "utun4" && $0.isVPN })
}

@Test("nettop 明细 CSV 可以关联连接到所属进程")
func trafficParserReadsConnections() {
    let output = """
    ,bytes_in,bytes_out,
    WeChat.486,200,300,
    tcp4 10.0.0.2:60000<->1.2.3.4:443,100,50,
    udp4 *:5353<->*:*,0,0,
    """

    let reading = NetworkTrafficParser.reading(from: output, timestamp: 10)

    #expect(reading.connections.count == 2)
    #expect(reading.connections[0].pid == 486)
    #expect(reading.connections[0].transport == .tcp)
    #expect(reading.connections[0].endpoint.contains("1.2.3.4:443"))
    #expect(reading.connections[1].transport == .udp)
}

@Test("同名 App 使用 Bundle ID 独立聚合")
func trafficCalculatorKeepsCanonicalAppIdentity() {
    let first = NetworkAppIdentity(
        id: "bundle:com.example.one",
        displayName: "Editor",
        bundleIdentifier: "com.example.one",
        bundlePath: "/Applications/One.app",
        executablePath: "/Applications/One.app/Contents/MacOS/One",
        kind: .application
    )
    let second = NetworkAppIdentity(
        id: "bundle:com.example.two",
        displayName: "Editor",
        bundleIdentifier: "com.example.two",
        bundlePath: "/Applications/Two.app",
        executablePath: "/Applications/Two.app/Contents/MacOS/Two",
        kind: .application
    )
    let previous = NetworkTrafficReading(
        timestamp: 10,
        apps: [
            .init(identity: first, pid: 1, receivedBytes: 100, sentBytes: 100),
            .init(identity: second, pid: 2, receivedBytes: 100, sentBytes: 100)
        ],
        status: .available
    )
    let current = NetworkTrafficReading(
        timestamp: 12,
        apps: [
            .init(identity: first, pid: 1, receivedBytes: 500, sentBytes: 100),
            .init(identity: second, pid: 2, receivedBytes: 100, sentBytes: 700)
        ],
        status: .available
    )

    let result = NetworkTrafficCalculator.calculate(current: current, previous: previous, sessionTotals: [:])

    #expect(Set(result.apps.map(\.id)) == Set([first.id, second.id]))
    #expect(result.apps.allSatisfy { $0.appName == "Editor" })
}

@Test("退出的 App 会以历史行保留")
func trafficCalculatorRetainsHistoricalApp() {
    let identity = NetworkAppIdentity(
        id: "bundle:com.example.reader",
        displayName: "Reader",
        bundleIdentifier: "com.example.reader",
        bundlePath: "/Applications/Reader.app",
        executablePath: nil,
        kind: .application
    )
    let previous = NetworkTrafficReading(
        timestamp: 10,
        apps: [.init(identity: identity, pid: 2, receivedBytes: 100, sentBytes: 50)],
        status: .available
    )
    let current = NetworkTrafficReading(
        timestamp: 12,
        apps: [.init(identity: identity, pid: 2, receivedBytes: 300, sentBytes: 100)],
        status: .available
    )
    let active = NetworkTrafficCalculator.calculate(current: current, previous: previous, sessionTotals: [:])
    let gone = NetworkTrafficCalculator.calculate(
        current: NetworkTrafficReading(timestamp: 14, apps: [], status: .available),
        previous: current,
        sessionTotals: active.sessionTotals,
        knownIdentities: [identity.id: identity]
    )

    #expect(gone.apps.count == 1)
    #expect(gone.apps[0].isHistoricalOnly)
    #expect(gone.apps[0].sessionDownloadedBytes == 200)
}

@Test("流量查询可以限制网卡和传输协议")
func trafficQueryBuildsScopedArguments() {
    let query = NetworkTrafficQuery(interface: .wifi, transport: .tcp)

    #expect(query.commandArguments.contains("-m"))
    #expect(query.commandArguments.contains("tcp"))
    #expect(query.commandArguments.contains("-t"))
    #expect(query.commandArguments.contains("wifi"))
    #expect(!NetworkTrafficQuery(interface: .all, transport: .all).commandArguments.contains("-t"))
}

@Test("历史数据可以写入并按 ISO8601 重新读取")
func trafficHistoryStoreRoundTrips() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("network-traffic-\(UUID().uuidString).json")
    let store = NetworkTrafficHistoryStore(
        fileURL: url,
        now: { Date(timeIntervalSince1970: 120) }
    )
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let bucket = NetworkTrafficHistoryBucket(
        timestamp: Date(timeIntervalSince1970: 120),
        queryKey: NetworkTrafficQuery.default.storageKey,
        apps: [identity.id: NetworkTrafficHistoryAppSample(
            identity: identity,
            downloadedBytes: 12,
            uploadedBytes: 8
        )]
    )

    store.save([bucket])
    #expect(store.load() == [bucket])
    try? FileManager.default.removeItem(at: url)
}

@Test("历史存储按真实时间清理所有查询范围")
func trafficHistoryStorePrunesExpiredBucketsAcrossQueries() {
    let now = Date(timeIntervalSince1970: 40 * 24 * 60 * 60)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("network-traffic-pruning-\(UUID().uuidString).sqlite3")
    let store = NetworkTrafficHistoryStore(fileURL: url, now: { now })
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let oldBucket = NetworkTrafficHistoryBucket(
        timestamp: now.addingTimeInterval(-31 * 24 * 60 * 60),
        queryKey: "wifi:tcp",
        apps: [identity.id: .init(identity: identity, downloadedBytes: 10, uploadedBytes: 2)]
    )
    let currentBucket = NetworkTrafficHistoryBucket(
        timestamp: now.addingTimeInterval(-60),
        queryKey: "external:all",
        apps: [identity.id: .init(identity: identity, downloadedBytes: 20, uploadedBytes: 4)]
    )

    store.save([oldBucket, currentBucket])

    #expect(store.load() == [currentBucket])
    let header = (try? Data(contentsOf: url).prefix(16)).map { String(decoding: $0, as: UTF8.self) }
    #expect(header == "SQLite format 3\0")
    try? FileManager.default.removeItem(at: url)
}

@Test("清除历史只删除当前查询范围")
func trafficHistoryStoreClearsOneQuery() {
    let now = Date(timeIntervalSince1970: 40 * 24 * 60 * 60)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("network-traffic-clear-query-\(UUID().uuidString).sqlite3")
    let store = NetworkTrafficHistoryStore(fileURL: url, now: { now })
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let first = NetworkTrafficHistoryBucket(
        timestamp: now,
        queryKey: "wifi:tcp",
        apps: [identity.id: .init(identity: identity, downloadedBytes: 10, uploadedBytes: 2)]
    )
    let second = NetworkTrafficHistoryBucket(
        timestamp: now,
        queryKey: "external:all",
        apps: [identity.id: .init(identity: identity, downloadedBytes: 20, uploadedBytes: 4)]
    )

    store.save([first, second])
    store.clear(queryKey: first.queryKey)

    #expect(store.load() == [second])
    try? FileManager.default.removeItem(at: url)
}

@Test("旧版 JSON 历史首次启动会迁移到 SQLite")
func trafficHistoryStoreMigratesLegacyJSON() throws {
    let now = Date(timeIntervalSince1970: 40 * 24 * 60 * 60)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("network-traffic-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let databaseURL = directory.appendingPathComponent("history.sqlite3")
    let legacyURL = directory.appendingPathComponent("history.json")
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let bucket = NetworkTrafficHistoryBucket(
        timestamp: now.addingTimeInterval(-60),
        queryKey: NetworkTrafficQuery.default.storageKey,
        apps: [identity.id: .init(identity: identity, downloadedBytes: 10, uploadedBytes: 2)]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([bucket]).write(to: legacyURL)

    let store = NetworkTrafficHistoryStore(
        fileURL: databaseURL,
        legacyFileURL: legacyURL,
        now: { now }
    )

    #expect(store.load() == [bucket])
    #expect(store.load() == [bucket])
    try? FileManager.default.removeItem(at: directory)
}

@Test("历史存储只加载当前查询并压缩一天以前的分钟桶")
func trafficHistoryStoreLoadsCurrentQueryWithTieredCompaction() {
    let now = Date(timeIntervalSince1970: 40 * 24 * 60 * 60)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("network-traffic-tiered-\(UUID().uuidString).sqlite3")
    let store = NetworkTrafficHistoryStore(fileURL: url, now: { now })
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let oldBase = floor(now.addingTimeInterval(-2 * 24 * 60 * 60).timeIntervalSince1970 / 7_200) * 7_200
    let buckets = [
        NetworkTrafficHistoryBucket(
            timestamp: Date(timeIntervalSince1970: oldBase + 60),
            queryKey: "external:all",
            apps: [identity.id: .init(identity: identity, downloadedBytes: 10, uploadedBytes: 2)]
        ),
        NetworkTrafficHistoryBucket(
            timestamp: Date(timeIntervalSince1970: oldBase + 120),
            queryKey: "external:all",
            apps: [identity.id: .init(identity: identity, downloadedBytes: 20, uploadedBytes: 4)]
        ),
        NetworkTrafficHistoryBucket(
            timestamp: now.addingTimeInterval(-60),
            queryKey: "wifi:tcp",
            apps: [identity.id: .init(identity: identity, downloadedBytes: 100, uploadedBytes: 40)]
        )
    ]
    store.save(buckets)

    let loaded = store.load(queryKey: "external:all")

    #expect(loaded.count == 1)
    #expect(loaded[0].timestamp == Date(timeIntervalSince1970: oldBase))
    #expect(loaded[0].apps[identity.id]?.downloadedBytes == 30)
    #expect(loaded[0].apps[identity.id]?.uploadedBytes == 6)
    try? FileManager.default.removeItem(at: url)
}

@MainActor
@Test("服务会记录历史并触发高流量提醒")
func networkTrafficServiceRecordsHistoryAndAlerts() async {
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let provider = TestNetworkTrafficProvider(readings: [
        NetworkTrafficReading(
            timestamp: 10,
            apps: [.init(identity: identity, pid: 2, receivedBytes: 100, sentBytes: 50)],
            status: .available
        ),
        NetworkTrafficReading(
            timestamp: 12,
            apps: [.init(identity: identity, pid: 2, receivedBytes: 2_100, sentBytes: 50)],
            status: .available
        ),
        NetworkTrafficReading(
            timestamp: 14,
            apps: [.init(identity: identity, pid: 2, receivedBytes: 4_100, sentBytes: 50)],
            status: .available
        )
    ])
    let historyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("network-traffic-service-\(UUID().uuidString).json")
    let defaultsName = "NetworkTrafficServiceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsName)!
    let alerter = TestNetworkTrafficAlerter()
    let service = NetworkTrafficService(
        provider: provider,
        historyStore: NetworkTrafficHistoryStore(fileURL: historyURL),
        userDefaults: defaults,
        alerter: alerter
    )
    service.alertThresholdBytesPerSecond = 500
    service.start()
    await service.refresh()
    await service.refresh()
    await service.refresh()

    #expect(service.snapshot.isAvailable)
    #expect(service.snapshot.history.count == 1)
    #expect(alerter.sentAppIDs == [identity.id])

    service.stop()
    try? FileManager.default.removeItem(at: historyURL)
    defaults.removePersistentDomain(forName: defaultsName)
}

@MainActor
@Test("高流量提醒需要持续超过阈值并在回落后重新触发")
func networkTrafficAlertRequiresSustainedTraffic() async {
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let readings = [
        (10, 100),
        (12, 2_100),
        (14, 4_100),
        (16, 4_100),
        (18, 6_100),
        (20, 8_100),
        (22, 10_100),
        (24, 12_100)
    ].map { timestamp, receivedBytes in
        NetworkTrafficReading(
            timestamp: TimeInterval(timestamp),
            apps: [.init(identity: identity, pid: 2, receivedBytes: receivedBytes, sentBytes: 0)],
            status: .available
        )
    }
    let provider = TestNetworkTrafficProvider(readings: readings)
    let defaultsName = "NetworkTrafficAlertTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsName)!
    let alerter = TestNetworkTrafficAlerter()
    var currentDate = Date(timeIntervalSince1970: 1_000)
    let historyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("network-traffic-alert-\(UUID().uuidString).json")
    let service = NetworkTrafficService(
        provider: provider,
        historyStore: NetworkTrafficHistoryStore(fileURL: historyURL),
        userDefaults: defaults,
        alerter: alerter,
        now: { currentDate }
    )
    service.alertThresholdBytesPerSecond = 500
    service.start()
    for _ in 0..<6 {
        await service.refresh()
    }

    #expect(alerter.sentAppIDs == [identity.id])

    currentDate.addTimeInterval(300)
    await service.refresh()
    await service.refresh()
    #expect(alerter.sentAppIDs == [identity.id, identity.id])

    service.stop()
    try? FileManager.default.removeItem(at: historyURL)
    defaults.removePersistentDomain(forName: defaultsName)
}

@MainActor
@Test("切换查询范围后返回会保留本次运行累计")
func networkTrafficServicePreservesSessionTotalsPerQuery() async {
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let provider = TestNetworkTrafficProvider(readings: [
        .init(timestamp: 10, apps: [.init(identity: identity, pid: 2, receivedBytes: 100, sentBytes: 0)], status: .available),
        .init(timestamp: 12, apps: [.init(identity: identity, pid: 2, receivedBytes: 500, sentBytes: 0)], status: .available),
        .init(timestamp: 14, apps: [.init(identity: identity, pid: 2, receivedBytes: 800, sentBytes: 0)], status: .available),
        .init(timestamp: 16, apps: [.init(identity: identity, pid: 2, receivedBytes: 900, sentBytes: 0)], status: .available),
        .init(timestamp: 18, apps: [.init(identity: identity, pid: 2, receivedBytes: 1_000, sentBytes: 0)], status: .available),
        .init(timestamp: 20, apps: [.init(identity: identity, pid: 2, receivedBytes: 1_200, sentBytes: 0)], status: .available)
    ])
    let defaultsName = "NetworkTrafficQuerySessions.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsName)!
    let historyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("network-traffic-query-sessions-\(UUID().uuidString).sqlite3")
    let service = NetworkTrafficService(
        provider: provider,
        historyStore: NetworkTrafficHistoryStore(fileURL: historyURL),
        userDefaults: defaults,
        alerter: TestNetworkTrafficAlerter()
    )

    await service.refresh()
    await service.refresh()
    #expect(service.snapshot.apps.first?.sessionDownloadedBytes == 400)

    service.setQuery(.init(interface: .wifi, transport: .tcp))
    await service.refresh()
    await service.refresh()

    service.setQuery(.default)
    await service.refresh()
    await service.refresh()
    #expect(service.snapshot.apps.first?.sessionDownloadedBytes == 600)

    service.stop()
    try? FileManager.default.removeItem(at: historyURL)
    defaults.removePersistentDomain(forName: defaultsName)
}

@Test("采样进程可以排空大输出并在超时后终止")
func networkTrafficProcessRunnerHandlesLargeOutputAndTimeout() async {
    let largeOutput = await NetworkTrafficProcessRunner(timeout: 3).run(
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: ["-c", "import sys; sys.stdout.write('x' * 200000)"]
    )
    #expect(largeOutput.terminationStatus == 0)
    #expect(largeOutput.standardOutput.utf8.count == 200_000)
    #expect(!largeOutput.timedOut)

    let timedOut = await NetworkTrafficProcessRunner(timeout: 0.2).run(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["2"]
    )
    #expect(timedOut.timedOut)
}

@MainActor
@Test("网络流量服务暴露失败次数和采样耗时诊断")
func networkTrafficServiceExposesFailureDiagnostics() async {
    let provider = TestNetworkTrafficProvider(readings: [
        NetworkTrafficReading(
            timestamp: 10,
            apps: [],
            status: .permissionDenied
        )
    ])
    let defaultsName = "NetworkTrafficDiagnosticsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsName)!
    let historyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("network-traffic-diagnostics-\(UUID().uuidString).json")
    let service = NetworkTrafficService(
        provider: provider,
        historyStore: NetworkTrafficHistoryStore(fileURL: historyURL),
        userDefaults: defaults,
        alerter: TestNetworkTrafficAlerter()
    )

    await service.refresh()

    #expect(service.snapshot.status == .permissionDenied)
    #expect(service.consecutiveSampleFailures == 1)
    #expect(service.lastSampleDuration != nil)
    #expect(service.lastSuccessfulSampleAt == nil)

    service.stop()
    try? FileManager.default.removeItem(at: historyURL)
    defaults.removePersistentDomain(forName: defaultsName)
}

@MainActor
@Test("网络流量服务只增量保存发生变化的分钟桶")
func networkTrafficServicePersistsOnlyDirtyHistoryBuckets() async {
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let currentDate = Date(timeIntervalSince1970: 1_788_480_000)
    let historicalBucket = NetworkTrafficHistoryBucket(
        timestamp: currentDate.addingTimeInterval(-3_600),
        queryKey: NetworkTrafficQuery.default.storageKey,
        apps: [
            identity.id: NetworkTrafficHistoryAppSample(
                identity: identity,
                downloadedBytes: 50,
                uploadedBytes: 20
            )
        ]
    )
    let historyStore = RecordingNetworkTrafficHistoryStore(buckets: [historicalBucket])
    let provider = TestNetworkTrafficProvider(readings: [
        .init(timestamp: 10, apps: [.init(identity: identity, pid: 2, receivedBytes: 100, sentBytes: 50)], status: .available),
        .init(timestamp: 12, apps: [.init(identity: identity, pid: 2, receivedBytes: 300, sentBytes: 150)], status: .available)
    ])
    let defaultsName = "NetworkTrafficDirtyPersistence.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsName)!
    let service = NetworkTrafficService(
        provider: provider,
        historyStore: historyStore,
        userDefaults: defaults,
        alerter: TestNetworkTrafficAlerter(),
        now: { currentDate }
    )

    await service.refresh()
    await service.refresh()

    #expect(historyStore.savedBatches.count == 1)
    #expect(historyStore.savedBatches[0].count == 1)
    #expect(historyStore.savedBatches[0][0].timestamp == currentDate)
    #expect(historyStore.savedBatches[0][0].apps[identity.id]?.downloadedBytes == 200)
    #expect(historyStore.savedBatches[0][0].apps[identity.id]?.uploadedBytes == 100)

    service.stop()
    defaults.removePersistentDomain(forName: defaultsName)
}

@MainActor
@Test("月度额度达到里程碑时各提醒一次")
func networkTrafficServiceSendsMonthlyQuotaMilestones() async {
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let provider = TestNetworkTrafficProvider(readings: [
        .init(timestamp: 10, apps: [.init(identity: identity, pid: 2, receivedBytes: 100, sentBytes: 0)], status: .available),
        .init(timestamp: 12, apps: [.init(identity: identity, pid: 2, receivedBytes: 950, sentBytes: 0)], status: .available),
        .init(timestamp: 14, apps: [.init(identity: identity, pid: 2, receivedBytes: 1_150, sentBytes: 0)], status: .available),
        .init(timestamp: 16, apps: [.init(identity: identity, pid: 2, receivedBytes: 1_350, sentBytes: 0)], status: .available)
    ])
    let defaultsName = "NetworkTrafficQuota.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsName)!
    let alerter = TestNetworkTrafficAlerter()
    let currentDate = Date(timeIntervalSince1970: 1_788_480_000)
    let historyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("network-traffic-quota-\(UUID().uuidString).sqlite3")
    let service = NetworkTrafficService(
        provider: provider,
        historyStore: NetworkTrafficHistoryStore(fileURL: historyURL, now: { currentDate }),
        userDefaults: defaults,
        alerter: alerter,
        now: { currentDate }
    )
    service.monthlyQuotaBytes = 1_000

    for _ in 0..<4 {
        await service.refresh()
    }

    #expect(alerter.sentQuotaStages == [.eightyPercent, .full])
    service.stop()
    try? FileManager.default.removeItem(at: historyURL)
    defaults.removePersistentDomain(forName: defaultsName)
}

@Test("网络流量导出会保留 App、进程和连接字段")
func networkTrafficExporterIncludesDetails() throws {
    let identity = NetworkAppIdentity(
        id: "bundle:com.example.editor",
        displayName: "Photo, Editor",
        bundleIdentifier: "com.example.editor",
        bundlePath: "/Applications/Editor.app",
        executablePath: "/Applications/Editor.app/Contents/MacOS/Editor",
        kind: .application
    )
    let app = NetworkAppTrafficSnapshot(
        identity: identity,
        downloadBytesPerSecond: 20,
        uploadBytesPerSecond: 10,
        sessionDownloadedBytes: 200,
        sessionUploadedBytes: 100,
        processes: [
            NetworkProcessTrafficSnapshot(
                pid: 42,
                processName: "Editor",
                downloadBytesPerSecond: 20,
                uploadBytesPerSecond: 10,
                currentDownloadedBytes: 40,
                currentUploadedBytes: 20
            )
        ],
        connections: [
            NetworkConnectionTrafficSnapshot(
                transport: .tcp,
                endpoint: "1.2.3.4:443",
                downloadedBytes: 40,
                uploadedBytes: 20
            )
        ]
    )
    let snapshot = NetworkTrafficSnapshot(
        apps: [app],
        status: .available,
        query: .default,
        lastUpdated: Date(timeIntervalSince1970: 120),
        history: []
    )

    let csv = NetworkTrafficExporter.csv(snapshot)
    #expect(csv.contains("\"Photo, Editor\""))
    #expect(csv.contains("1.2.3.4:443"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(NetworkTrafficSnapshot.self, from: NetworkTrafficExporter.json(snapshot))
    #expect(decoded == snapshot)
}

@Test("网络流量历史可以导出为按时间排序的 CSV")
func networkTrafficHistoryExporterIncludesTimeBuckets() {
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let snapshot = NetworkTrafficSnapshot(
        apps: [],
        status: .available,
        query: .default,
        lastUpdated: nil,
        history: [
            NetworkTrafficHistoryBucket(
                timestamp: Date(timeIntervalSince1970: 60),
                queryKey: NetworkTrafficQuery.default.storageKey,
                apps: [identity.id: NetworkTrafficHistoryAppSample(
                    identity: identity,
                    downloadedBytes: 20,
                    uploadedBytes: 5
                )]
            ),
            NetworkTrafficHistoryBucket(
                timestamp: Date(timeIntervalSince1970: 0),
                queryKey: NetworkTrafficQuery.default.storageKey,
                apps: [identity.id: NetworkTrafficHistoryAppSample(
                    identity: identity,
                    downloadedBytes: 10,
                    uploadedBytes: 2
                )]
            )
        ]
    )

    let csv = NetworkTrafficExporter.historyCSV(snapshot)
    let lines = csv.split(separator: "\n").map(String.init)
    #expect(lines.first == "timestamp,query,app,kind,bundle_id,downloaded_bytes,uploaded_bytes,total_bytes")
    #expect(lines.count == 3)
    #expect(lines[1].contains("1970-01-01T00:00:00Z"))
    #expect(lines[1].contains(",10,2,12"))
    #expect(lines[2].contains(",20,5,25"))
}

@Test("网络连接 endpoint 可以正确拆分主机和端口")
func networkEndpointParserHandlesIPv4AndIPv6() {
    let ipv4 = NetworkEndpointParser.parse("api.example.com:8443")
    #expect(ipv4.host == "api.example.com")
    #expect(ipv4.port == 8443)

    let ipv6 = NetworkEndpointParser.parse("[2001:db8::1]:443")
    #expect(ipv6.host == "2001:db8::1")
    #expect(ipv6.port == 443)

    let bareIPv6 = NetworkEndpointParser.parse("2001:db8::1")
    #expect(bareIPv6.host == "2001:db8::1")
    #expect(bareIPv6.port == nil)

    let connection = NetworkEndpointParser.parse("10.0.0.2:60000<->1.2.3.4:443")
    #expect(connection.localHost == "10.0.0.2")
    #expect(connection.localPort == 60_000)
    #expect(connection.host == "1.2.3.4")
    #expect(connection.port == 443)
}

@Test("重复连接会按协议与地址聚合")
func networkConnectionsAggregateDuplicateEndpoints() {
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let readings = [
        NetworkConnectionTrafficReading(
            identity: identity,
            pid: 1,
            transport: .tcp,
            endpoint: "10.0.0.2:50000<->1.2.3.4:443",
            receivedBytes: 100,
            sentBytes: 20
        ),
        NetworkConnectionTrafficReading(
            identity: identity,
            pid: 2,
            transport: .tcp,
            endpoint: "10.0.0.2:50000<->1.2.3.4:443",
            receivedBytes: 50,
            sentBytes: 30
        )
    ]

    let connections = NetworkConnectionTrafficAggregator.snapshots(from: readings)

    #expect(connections == [
        NetworkConnectionTrafficSnapshot(
            transport: .tcp,
            endpoint: "10.0.0.2:50000<->1.2.3.4:443",
            downloadedBytes: 150,
            uploadedBytes: 50
        )
    ])
}

@Test("后台采样会按实时视图和提醒状态动态降频")
func networkTrafficSamplingPolicyUsesAdaptiveIntervals() {
    #expect(NetworkTrafficSamplingPolicy.interval(liveObserverCount: 1, alertEnabled: false) == 2)
    #expect(NetworkTrafficSamplingPolicy.interval(liveObserverCount: 0, alertEnabled: true) == 10)
    #expect(NetworkTrafficSamplingPolicy.interval(liveObserverCount: 0, alertEnabled: false) == 60)
}

@Test("脱敏导出会隐藏 App 身份、进程和连接端点")
func networkTrafficRedactedExportRemovesSensitiveFields() {
    let identity = NetworkAppIdentity(
        id: "com.example.browser",
        displayName: "Example Browser",
        bundleIdentifier: "com.example.browser",
        bundlePath: "/Applications/Example Browser.app",
        executablePath: "/Applications/Example Browser.app/Contents/MacOS/Example Browser",
        kind: .application
    )
    let snapshot = NetworkTrafficSnapshot(
        apps: [
            NetworkAppTrafficSnapshot(
                identity: identity,
                downloadBytesPerSecond: 10,
                uploadBytesPerSecond: 5,
                sessionDownloadedBytes: 100,
                sessionUploadedBytes: 50,
                processes: [
                    NetworkProcessTrafficSnapshot(
                        pid: 42,
                        processName: "Example Browser Helper",
                        downloadBytesPerSecond: 10,
                        uploadBytesPerSecond: 5,
                        currentDownloadedBytes: 100,
                        currentUploadedBytes: 50
                    )
                ],
                connections: [
                    NetworkConnectionTrafficSnapshot(
                        transport: .tcp,
                        endpoint: "192.0.2.1:443",
                        downloadedBytes: 100,
                        uploadedBytes: 50
                    )
                ]
            )
        ],
        status: .available,
        query: .default,
        lastUpdated: Date(timeIntervalSince1970: 10),
        history: [
            NetworkTrafficHistoryBucket(
                timestamp: Date(timeIntervalSince1970: 10),
                queryKey: NetworkTrafficQuery.default.storageKey,
                apps: [
                    identity.id: NetworkTrafficHistoryAppSample(
                        identity: identity,
                        downloadedBytes: 100,
                        uploadedBytes: 50
                    )
                ]
            )
        ]
    )

    let redacted = NetworkTrafficExportSanitizer.make(snapshot, privacy: .redacted)
    let app = try! #require(redacted.apps.first)

    #expect(app.identity.id == "app-1")
    #expect(app.identity.displayName == "App 1")
    #expect(app.identity.bundleIdentifier == nil)
    #expect(app.identity.bundlePath == nil)
    #expect(app.identity.executablePath == nil)
    #expect(app.processes.first?.pid == 0)
    #expect(app.processes.first?.processName == "redacted")
    #expect(app.connections.first?.endpoint == "redacted")
    #expect(redacted.history.first?.apps["app-1"]?.identity == app.identity)
    #expect(!NetworkTrafficExporter.csv(redacted).contains("192.0.2.1"))
    #expect(!String(data: try! NetworkTrafficExporter.json(redacted), encoding: .utf8)!.contains("Example Browser"))
}

@Test("历史存储策略会限制数据库与 WAL 文件大小")
func networkTrafficHistoryStoragePolicyCapsSQLiteFiles() {
    #expect(NetworkTrafficHistoryStoragePolicy.maximumDatabaseBytes == 64 * 1_024 * 1_024)
    #expect(NetworkTrafficHistoryStoragePolicy.maximumWALBytes == 8 * 1_024 * 1_024)
    #expect(NetworkTrafficHistoryStoragePolicy.maximumPageCount(pageSize: 4_096) == 16_384)
}

@Test("网络流量治理功能在所有内置语言中都有文案")
func networkTrafficGovernanceLocalizationKeysExistInEveryLocale() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let keys = [
        "traffic.diagnostics",
        "traffic.exportPrivacy",
        "traffic.clearAllHistory"
    ]

    for locale in ["en", "ja", "ko", "zh-Hans", "zh-Hant"] {
        let stringsURL = projectRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(locale).lproj")
            .appendingPathComponent("Localizable.strings")
        let source = try String(contentsOf: stringsURL, encoding: .utf8)
        for key in keys {
            #expect(source.contains("\"\(key)\""), "\(locale) 缺少 \(key)")
        }
    }
}

@Test("历史存储可以报告占用并清除所有查询范围")
func networkTrafficHistoryStoreReportsUsageAndClearsAll() {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("network-traffic-usage-\(UUID().uuidString).sqlite3")
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let store = NetworkTrafficHistoryStore(fileURL: databaseURL)
    store.save([
        NetworkTrafficHistoryBucket(
            timestamp: Date(),
            queryKey: NetworkTrafficQuery.default.storageKey,
            apps: [
                identity.id: NetworkTrafficHistoryAppSample(
                    identity: identity,
                    downloadedBytes: 10,
                    uploadedBytes: 20
                )
            ]
        )
    ])

    #expect(store.storageUsage().totalBytes > 0)
    #expect(!store.load(queryKey: nil).isEmpty)

    store.clearAll()

    #expect(store.load(queryKey: nil).isEmpty)
    try? FileManager.default.removeItem(at: databaseURL)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
}

@MainActor
@Test("服务诊断会暴露失败原因和历史存储占用")
func networkTrafficServiceDiagnosticsIncludeFailureAndStorage() async {
    let provider = TestNetworkTrafficProvider(readings: [
        NetworkTrafficReading(timestamp: 10, apps: [], status: .timedOut)
    ])
    let service = NetworkTrafficService(
        provider: provider,
        historyStore: RecordingNetworkTrafficHistoryStore(buckets: [], storageUsage: .init(databaseBytes: 1_024, walBytes: 24)),
        userDefaults: UserDefaults(suiteName: "NetworkTrafficDiagnosticsSummary.\(UUID().uuidString)")!,
        alerter: TestNetworkTrafficAlerter()
    )

    await service.refresh()

    #expect(service.diagnostics.lastFailureStatus == .timedOut)
    #expect(service.diagnostics.consecutiveSampleFailures == 1)
    #expect(service.diagnostics.historyStorage.totalBytes == 1_048)
    service.stop()
}

@MainActor
@Test("清除全部流量数据会同时清空历史和本次运行累计")
func networkTrafficServiceClearAllHistoryResetsEveryScope() async {
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let store = RecordingNetworkTrafficHistoryStore(buckets: [
        NetworkTrafficHistoryBucket(
            timestamp: Date(),
            queryKey: NetworkTrafficQuery(interface: .wifi, transport: .tcp).storageKey,
            apps: [
                identity.id: NetworkTrafficHistoryAppSample(
                    identity: identity,
                    downloadedBytes: 100,
                    uploadedBytes: 20
                )
            ]
        )
    ])
    let service = NetworkTrafficService(
        provider: TestNetworkTrafficProvider(readings: [
            NetworkTrafficReading(
                timestamp: 10,
                apps: [.init(identity: identity, pid: 2, receivedBytes: 100, sentBytes: 20)],
                status: .available
            ),
            NetworkTrafficReading(
                timestamp: 12,
                apps: [.init(identity: identity, pid: 2, receivedBytes: 300, sentBytes: 70)],
                status: .available
            )
        ]),
        historyStore: store,
        userDefaults: UserDefaults(suiteName: "NetworkTrafficClearAll.\(UUID().uuidString)")!,
        alerter: TestNetworkTrafficAlerter()
    )

    await service.refresh()
    await service.refresh()
    #expect(service.snapshot.apps.first?.sessionDownloadedBytes == 200)

    service.clearAllHistory()

    #expect(service.snapshot.apps.isEmpty)
    #expect(service.snapshot.history.isEmpty)
    #expect(store.load(queryKey: nil).isEmpty)
    service.stop()
}

@MainActor
@Test("连接明细读取失败会暴露错误并允许重试")
func networkTrafficServiceExposesConnectionLoadFailure() async {
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let summary = NetworkTrafficReading(
        timestamp: 10,
        apps: [.init(identity: identity, pid: 2, receivedBytes: 100, sentBytes: 50)],
        status: .available
    )
    let failure = NetworkTrafficReading(
        timestamp: 10,
        apps: [],
        status: .commandFailed
    )
    let provider = TestNetworkTrafficProvider(readings: [summary], connectionReading: failure)
    let service = NetworkTrafficService(
        provider: provider,
        historyStore: NetworkTrafficHistoryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("network-traffic-connection-failure-\(UUID().uuidString).sqlite3")
        ),
        userDefaults: UserDefaults(suiteName: "NetworkTrafficConnectionFailure.\(UUID().uuidString)")!,
        alerter: TestNetworkTrafficAlerter()
    )
    await service.refresh()
    service.loadConnections(for: identity.id)

    for _ in 0..<20 where service.connectionLoadError(for: identity.id) == nil {
        await Task.yield()
    }

    #expect(service.connectionLoadError(for: identity.id) == .commandFailed)
    #expect(!service.hasLoadedConnections(for: identity.id))
    service.stop()
}

@MainActor
@Test("展开 App 后可以异步加载连接明细")
func networkTrafficServiceLoadsConnections() async {
    let identity = NetworkAppIdentity.fallback(processName: "Safari")
    let summary = NetworkTrafficReading(
        timestamp: 10,
        apps: [.init(identity: identity, pid: 2, receivedBytes: 100, sentBytes: 50)],
        status: .available
    )
    let details = NetworkTrafficReading(
        timestamp: 10,
        apps: summary.apps,
        connections: [
            NetworkConnectionTrafficReading(
                identity: identity,
                pid: 2,
                transport: .tcp,
                endpoint: "1.2.3.4:443",
                receivedBytes: 90,
                sentBytes: 30
            )
        ],
        status: .available
    )
    let provider = TestNetworkTrafficProvider(readings: [summary], connectionReading: details)
    let service = NetworkTrafficService(
        provider: provider,
        historyStore: NetworkTrafficHistoryStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("network-traffic-connections-\(UUID().uuidString).json")
        ),
        userDefaults: UserDefaults(suiteName: "NetworkTrafficConnections.\(UUID().uuidString)")!,
        alerter: TestNetworkTrafficAlerter()
    )
    await service.refresh()
    service.loadConnections(for: identity.id)

    for _ in 0..<20 where !service.hasLoadedConnections(for: identity.id) {
        await Task.yield()
    }

    #expect(service.hasLoadedConnections(for: identity.id))
    #expect(service.snapshot.apps.first?.connections.first?.endpoint == "1.2.3.4:443")
    service.stop()
}

private final class TestNetworkTrafficProvider: NetworkTrafficProviding, @unchecked Sendable {
    private let readings: [NetworkTrafficReading]
    private let connectionReading: NetworkTrafficReading?
    private var index = 0

    init(readings: [NetworkTrafficReading], connectionReading: NetworkTrafficReading? = nil) {
        self.readings = readings
        self.connectionReading = connectionReading
    }

    func read(query: NetworkTrafficQuery) async -> NetworkTrafficReading {
        defer { index += 1 }
        return readings[min(index, readings.count - 1)]
    }

    func read(query: NetworkTrafficQuery, includeConnections: Bool) async -> NetworkTrafficReading {
        if includeConnections, let connectionReading { return connectionReading }
        return await read(query: query)
    }
}

@MainActor
private final class TestNetworkTrafficAlerter: NetworkTrafficAlerting {
    private(set) var sentAppIDs: [String] = []
    private(set) var sentQuotaStages: [NetworkTrafficQuotaStage] = []

    func requestPermission() {}

    func send(app: NetworkAppTrafficSnapshot, threshold: Int64) {
        sentAppIDs.append(app.id)
    }

    func sendQuota(stage: NetworkTrafficQuotaStage, usedBytes: Int64, quotaBytes: Int64) {
        sentQuotaStages.append(stage)
    }
}

private final class RecordingNetworkTrafficHistoryStore: NetworkTrafficHistoryStoring {
    private var buckets: [NetworkTrafficHistoryBucket]
    private(set) var savedBatches: [[NetworkTrafficHistoryBucket]] = []
    private let configuredStorageUsage: NetworkTrafficHistoryStorageUsage

    init(
        buckets: [NetworkTrafficHistoryBucket],
        storageUsage: NetworkTrafficHistoryStorageUsage = .init()
    ) {
        self.buckets = buckets
        configuredStorageUsage = storageUsage
    }

    func load(queryKey: String?) -> [NetworkTrafficHistoryBucket] {
        buckets.filter { queryKey == nil || $0.queryKey == queryKey }
    }

    func save(_ buckets: [NetworkTrafficHistoryBucket]) {
        savedBatches.append(buckets)
        for bucket in buckets {
            if let index = self.buckets.firstIndex(where: { $0.id == bucket.id }) {
                self.buckets[index] = bucket
            } else {
                self.buckets.append(bucket)
            }
        }
    }

    func clear(queryKey: String) {
        buckets.removeAll { $0.queryKey == queryKey }
    }

    func clearAll() {
        buckets.removeAll()
    }

    func storageUsage() -> NetworkTrafficHistoryStorageUsage {
        configuredStorageUsage
    }
}
