import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum NetworkTrafficAppFilter: String, CaseIterable, Sendable {
    case all
    case applications
    case systemServices

    var titleKey: String {
        switch self {
        case .all: return "traffic.filter.all"
        case .applications: return "traffic.filter.applications"
        case .systemServices: return "traffic.filter.systemServices"
        }
    }
}

enum NetworkTrafficSort: String, CaseIterable, Sendable {
    case activity
    case total
    case name
    case download
    case upload

    var titleKey: String {
        switch self {
        case .activity: return "traffic.sort.activity"
        case .total: return "traffic.sort.total"
        case .name: return "traffic.sort.name"
        case .download: return "traffic.sort.download"
        case .upload: return "traffic.sort.upload"
        }
    }
}

enum NetworkTrafficHistoryChartLayout {
    static func barWidth(totalWidth: CGFloat, sampleCount: Int, spacing: CGFloat = 2) -> CGFloat {
        guard totalWidth > 0, sampleCount > 0 else { return 0 }
        guard sampleCount > 1 else { return 8 }

        let availableWidth = (totalWidth - CGFloat(sampleCount - 1) * spacing) / CGFloat(sampleCount)
        return min(10, max(3, availableWidth))
    }
}

enum NetworkTrafficMiniTrendLayout {
    // 柱子按画布分配宽度，避免固定柱宽在采样增多时溢出并覆盖相邻文字。
    static func barFrames(bytes: [Int64], size: CGSize) -> [CGRect] {
        guard !bytes.isEmpty, size.width > 0, size.height > 0 else { return [] }
        let maximum = max(bytes.max() ?? 0, 1)
        let slotWidth = size.width / CGFloat(bytes.count)
        return bytes.enumerated().map { index, value in
            let x = CGFloat(index) * slotWidth
            let height = min(size.height, max(1, CGFloat(max(value, 0)) / CGFloat(maximum) * size.height))
            return CGRect(
                x: x, y: size.height - height,
                width: min(slotWidth * 0.7, size.width - x), height: height
            )
        }
    }
}

struct NetworkTrafficSettingsView: View {
    @State private var service = NetworkTrafficService.shared
    @State private var networkStatusService = NetworkStatusService.shared
    @State private var searchText = ""
    @State private var filter: NetworkTrafficAppFilter = .all
    @State private var sort: NetworkTrafficSort = .activity
    @State private var historyRange: NetworkTrafficHistoryRange = .hour
    @State private var expandedAppIDs: Set<String> = []
    @State private var showingClearHistory = false
    @State private var showingClearAllHistory = false
    @State private var exportPrivacy: NetworkTrafficExportPrivacy = .redacted
    @State private var exportError: String?
    @State private var exportMessage: String?
    @State private var interfaceInfos: [NetworkTrafficInterfaceInfo] = []

    private var visibleApps: [NetworkAppTrafficSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return service.snapshot.apps
            .filter { app in
                switch filter {
                case .all: return true
                case .applications: return app.identity.kind == .application
                case .systemServices: return app.identity.kind != .application
                }
            }
            .filter { app in
                guard !query.isEmpty else { return true }
                return app.appName.lowercased().contains(query)
                    || (app.identity.bundleIdentifier?.lowercased().contains(query) == true)
                    || (app.identity.bundlePath?.lowercased().contains(query) == true)
                    || (app.identity.executablePath?.lowercased().contains(query) == true)
                    || app.processes.contains { $0.processName.lowercased().contains(query) }
                    || app.connections.contains { $0.endpoint.lowercased().contains(query) }
            }
            .sorted(by: sortComparator)
    }

    private var visibleAppIDs: Set<String> {
        Set(visibleApps.map(\.id))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                searchField
                queryControls
                networkQualityCard
                diagnosticsCard

                if service.isPaused {
                    statusBanner(
                        title: L("traffic.paused"),
                        symbol: "pause.circle.fill",
                        color: .orange
                    )
                }

                if !service.snapshot.isAvailable {
                    networkErrorBanner
                }
                if let exportMessage {
                    statusBanner(title: exportMessage, symbol: "checkmark.circle.fill", color: .green)
                }

                let apps = service.snapshot.apps
                if service.snapshot.isAvailable || !apps.isEmpty {
                    summary(visibleApps)
                    historyChart

                    if visibleApps.isEmpty {
                        ContentUnavailableView(
                            L("traffic.noMatches"),
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text(L("traffic.noMatchesDescription"))
                        )
                        .frame(maxWidth: .infinity, minHeight: 130)
                    } else {
                        LazyVStack(spacing: 6) {
                            ForEach(visibleApps) { app in
                                appRow(app)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        L("traffic.noApps"),
                        systemImage: "network.slash",
                        description: Text(L("traffic.emptyDescription"))
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                }

                footerActions
            }
            .padding(20)
        }
        .task {
            interfaceInfos = NetworkTrafficInterfaceInspector.read()
            networkStatusService.refresh()
            service.start()
            service.beginLiveView()
            defer { service.endLiveView() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                interfaceInfos = NetworkTrafficInterfaceInspector.read()
            }
        }
        .alert(L("traffic.clearHistoryTitle"), isPresented: $showingClearHistory) {
            Button(L("traffic.clearHistory"), role: .destructive) {
                service.clearHistory()
            }
            Button(L("update.cancel"), role: .cancel) {}
        } message: {
            Text(L("traffic.clearHistoryMessage"))
        }
        .alert(L("traffic.clearAllHistoryTitle"), isPresented: $showingClearAllHistory) {
            Button(L("traffic.clearAllHistory"), role: .destructive) {
                service.clearAllHistory()
            }
            Button(L("update.cancel"), role: .cancel) {}
        } message: {
            Text(L("traffic.clearAllHistoryMessage"))
        }
        .alert(
            L("traffic.exportFailed"),
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button(L("update.cancel"), role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? L("traffic.exportFailed"))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("traffic.title"))
                    .font(.title3.weight(.semibold))
                Text(L("traffic.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L("traffic.scopeValue", L(service.query.interface.titleKey), L(service.query.transport.titleKey)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                interfaceSummary
            }
            Spacer()
            Button {
                service.togglePaused()
            } label: {
                Image(systemName: service.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .help(L(service.isPaused ? "traffic.resume" : "traffic.pause"))
            .accessibilityLabel(L(service.isPaused ? "traffic.resume" : "traffic.pause"))

            Button {
                interfaceInfos = NetworkTrafficInterfaceInspector.read()
                Task { @MainActor in
                    await service.refresh()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L("traffic.refresh"))
            .accessibilityLabel(L("traffic.refresh"))
        }
    }

    @ViewBuilder
    private var interfaceSummary: some View {
        if let primary = interfaceInfos.first(where: { !$0.isVPN }) ?? interfaceInfos.first {
            HStack(spacing: 6) {
                Image(systemName: primary.isVPN ? "lock.shield" : "network")
                    .foregroundStyle(.secondary)
                Text(L("traffic.interfaceValue", primary.name))
                if let ipv4 = primary.ipv4 {
                    Text(L("traffic.ipv4Value", ipv4))
                }
                if let ipv6 = primary.ipv6 {
                    Text(L("traffic.ipv6Value", ipv6))
                }
                if let vpn = interfaceInfos.first(where: { $0.isVPN }) {
                    Text(L("traffic.vpnValue", vpn.name))
                        .foregroundStyle(.green)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        } else {
            Text(L("traffic.interfaceUnavailable"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var queryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker(L("traffic.interface"), selection: Binding(
                    get: { service.query.interface },
                    set: { service.setQuery(NetworkTrafficQuery(interface: $0, transport: service.query.transport)) }
                )) {
                    ForEach(NetworkTrafficInterface.allCases, id: \.self) { value in
                        Text(L(value.titleKey)).tag(value)
                    }
                }

                Picker(L("traffic.transport"), selection: Binding(
                    get: { service.query.transport },
                    set: { service.setQuery(NetworkTrafficQuery(interface: service.query.interface, transport: $0)) }
                )) {
                    ForEach(NetworkTrafficTransport.allCases, id: \.self) { value in
                        Text(L(value.titleKey)).tag(value)
                    }
                }

                Picker(L("traffic.filter"), selection: $filter) {
                    ForEach(NetworkTrafficAppFilter.allCases, id: \.self) { value in
                        Text(L(value.titleKey)).tag(value)
                    }
                }

                Picker(L("traffic.sort"), selection: $sort) {
                    ForEach(NetworkTrafficSort.allCases, id: \.self) { value in
                        Text(L(value.titleKey)).tag(value)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            HStack(spacing: 8) {
                Text(L("traffic.alert"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L("traffic.alert"), selection: Binding(
                    get: { service.alertThresholdBytesPerSecond },
                    set: { service.alertThresholdBytesPerSecond = $0 }
                )) {
                    Text(L("traffic.alert.off")).tag(Int64(0))
                    Text(L("traffic.alert.1MB")).tag(Int64(1_024 * 1_024))
                    Text(L("traffic.alert.5MB")).tag(Int64(5 * 1_024 * 1_024))
                    Text(L("traffic.alert.10MB")).tag(Int64(10 * 1_024 * 1_024))
                    Text(L("traffic.alert.50MB")).tag(Int64(50 * 1_024 * 1_024))
                }
                .labelsHidden()
                Text(L("traffic.alert.description"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                Text(L("traffic.menuBar"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L("traffic.menuBar"), selection: Binding(
                    get: { service.menuBarDisplayMode },
                    set: { service.menuBarDisplayMode = $0 }
                )) {
                    ForEach(NetworkTrafficMenuBarDisplayMode.allCases, id: \.self) { mode in
                        Text(L(mode.titleKey)).tag(mode)
                    }
                }
                .labelsHidden()

                Text(L("traffic.monthlyQuota"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L("traffic.monthlyQuota"), selection: Binding(
                    get: { service.monthlyQuotaBytes },
                    set: { service.monthlyQuotaBytes = $0 }
                )) {
                    Text(L("traffic.quota.off")).tag(Int64(0))
                    Text("10 GB").tag(Int64(10 * 1_024 * 1_024 * 1_024))
                    Text("50 GB").tag(Int64(50 * 1_024 * 1_024 * 1_024))
                    Text("100 GB").tag(Int64(100 * 1_024 * 1_024 * 1_024))
                    Text("500 GB").tag(Int64(500 * 1_024 * 1_024 * 1_024))
                    Text("1 TB").tag(Int64(1_024 * 1_024 * 1_024 * 1_024))
                }
                .labelsHidden()
                Text(L("traffic.quota.description"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .controlCenterSurface(tint: .teal)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(L("traffic.search"), text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel(L("traffic.search"))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("traffic.clearSearch"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 11))
    }

    private var networkQualityCard: some View {
        let snapshot = networkStatusService.snapshot
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("traffic.quality"), systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    networkStatusService.testLatency()
                } label: {
                    if networkStatusService.isLatencyTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(L("traffic.testQuality"), systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(networkStatusService.isLatencyTesting || !snapshot.isConnected)
            }

            HStack(spacing: 10) {
                qualityMetric(L("traffic.quality.latency"), snapshot.latencyMilliseconds.map { "\($0) ms" } ?? "--")
                qualityMetric(L("traffic.quality.jitter"), snapshot.jitterMilliseconds.map { "\($0) ms" } ?? "--")
                qualityMetric(L("traffic.quality.loss"), snapshot.packetLossPercent.map { String(format: "%.1f%%", $0) } ?? "--")
                qualityMetric(L("traffic.quality.dns"), snapshot.dnsMilliseconds.map { "\($0) ms" } ?? "--")
            }

            if !networkStatusService.recentTransitions.isEmpty {
                Divider()
                Text(L("traffic.networkChanges"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(networkStatusService.recentTransitions.suffix(3).reversed()) { transition in
                    HStack(spacing: 7) {
                        Text(transition.timestamp, style: .time)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Text(networkChangeDescription(transition))
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .controlCenterSurface(tint: .mint)
    }

    private func qualityMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var diagnosticsCard: some View {
        let diagnostics = service.diagnostics
        return VStack(alignment: .leading, spacing: 8) {
            Label(L("traffic.diagnostics"), systemImage: "stethoscope")
                .font(.caption.weight(.semibold))

            HStack(spacing: 10) {
                diagnosticsMetric(
                    L("traffic.diagnostics.sampleDuration"),
                    diagnostics.lastSampleDuration.map { String(format: "%.0f ms", $0 * 1_000) } ?? "--"
                )
                diagnosticsMetric(
                    L("traffic.diagnostics.failures"),
                    String(diagnostics.consecutiveSampleFailures)
                )
                diagnosticsMetric(
                    L("traffic.diagnostics.storage"),
                    formattedBytes(diagnostics.historyStorage.totalBytes)
                )
                diagnosticsMetric(
                    L("traffic.diagnostics.lastSuccess"),
                    diagnostics.lastSuccessfulSampleAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "--"
                )
            }

            if let status = diagnostics.lastFailureStatus {
                Text(L("traffic.diagnostics.lastFailure", statusTitle(status)))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .controlCenterSurface(tint: .indigo)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("traffic.diagnostics"))
    }

    private func diagnosticsMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func networkChangeDescription(_ transition: NetworkStatusTransition) -> String {
        L(
            "traffic.networkChangeValue",
            environmentDescription(transition.previous),
            environmentDescription(transition.current)
        )
    }

    private func environmentDescription(_ environment: NetworkEnvironmentSignature) -> String {
        guard environment.isConnected else { return L("network.offline") }
        let connection = environment.wifiName ?? environment.interfaceName ?? L("network.connection")
        return environment.vpnConnected ? "\(connection) · VPN" : connection
    }

    private func summary(_ apps: [NetworkAppTrafficSnapshot]) -> some View {
        let totals = NetworkTrafficSummary.make(apps)
        let today = NetworkTrafficPeriodSummary.make(
            from: service.snapshot.history,
            period: .today,
            queryKey: service.query.storageKey,
            appIDs: Set(apps.map(\.id))
        )
        let month = NetworkTrafficPeriodSummary.make(
            from: service.snapshot.history,
            period: .month,
            queryKey: service.query.storageKey,
            appIDs: Set(apps.map(\.id))
        )
        let quota = service.monthlyQuotaBytes

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                summaryMetric(title: L("traffic.downloadRate"), value: "↓ \(formattedRate(totals.downloadBytesPerSecond))", color: .cyan)
                summaryMetric(title: L("traffic.uploadRate"), value: "↑ \(formattedRate(totals.uploadBytesPerSecond))", color: .orange)
                summaryMetric(title: L("traffic.sessionDownload"), value: formattedBytes(totals.sessionDownloadedBytes), color: .secondary)
                summaryMetric(title: L("traffic.sessionUpload"), value: formattedBytes(totals.sessionUploadedBytes), color: .secondary)
            }
            Divider()
            HStack(spacing: 10) {
                summaryMetric(title: L("traffic.todayTotal"), value: formattedBytes(today.totalBytes), color: .teal)
                summaryMetric(title: L("traffic.monthTotal"), value: formattedBytes(month.totalBytes), color: .blue)
                if quota > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("traffic.quotaProgress", formattedBytes(month.totalBytes), formattedBytes(quota)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        ProgressView(value: min(Double(month.totalBytes) / Double(quota), 1))
                            .tint(month.totalBytes >= quota ? .red : .teal)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCenterSurface(tint: .teal)
    }

    private func summaryMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historyChart: some View {
        let points = NetworkTrafficHistorySeries.make(
            from: service.snapshot.history,
            range: historyRange,
            now: Date(),
            appIDs: visibleAppIDs
        )
        let stats = NetworkTrafficHistoryStats.make(
            from: service.snapshot.history,
            range: historyRange,
            now: Date(),
            appIDs: visibleAppIDs
        )
        let values = points.map(\.bytes)
        let maximum = max(values.max() ?? 0, 1)
        let ranking = Array(NetworkTrafficHistoryRanking.make(
            from: service.snapshot.history,
            range: historyRange,
            queryKey: service.query.storageKey,
            now: Date(),
            appIDs: visibleAppIDs
        ).prefix(5))

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L("traffic.history"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Picker(L("traffic.historyRange"), selection: $historyRange) {
                    ForEach(NetworkTrafficHistoryRange.allCases, id: \.self) { range in
                        Text(L(range.titleKey)).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .accessibilityLabel(L("traffic.historyRange"))
            }
            if service.snapshot.history.isEmpty {
                Text(L("traffic.noHistory"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            } else {
                GeometryReader { geometry in
                    let spacing: CGFloat = 2
                    let barWidth = NetworkTrafficHistoryChartLayout.barWidth(
                        totalWidth: geometry.size.width,
                        sampleCount: values.count,
                        spacing: spacing
                    )

                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.orange.opacity(0.78))
                                    .frame(height: CGFloat(point.uploadedBytes) / CGFloat(maximum) * 54)
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.cyan.opacity(0.78))
                                    .frame(height: max(CGFloat(point.downloadedBytes) / CGFloat(maximum) * 54, point.bytes > 0 ? 1 : 3))
                            }
                            .frame(width: barWidth, height: 54)
                            .help(historyPointDescription(point))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58)

                HStack(spacing: 8) {
                    historyMetric(L("traffic.rangeTotal"), formattedBytes(stats.totalBytes))
                    historyMetric(L("traffic.rangePeak"), formattedRate(Int64(Double(stats.peakBytes) / historyRange.interval)))
                    historyMetric(L("traffic.rangeAverage"), formattedRate(Int64(Double(stats.averageBytes) / historyRange.interval)))
                }

                if !ranking.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("traffic.rangeRanking"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach(Array(ranking.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 7) {
                                Text("\(index + 1)")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 14, alignment: .trailing)
                                Text(entry.identity.displayName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Spacer()
                                Text(formattedBytes(entry.totalBytes))
                                    .font(.caption2.weight(.medium))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .controlCenterSurface(tint: .blue)
    }

    private func historyMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historyPointDescription(_ point: NetworkTrafficHistoryPoint) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return L(
            "traffic.historyPoint",
            formatter.string(from: point.timestamp),
            formattedBytes(point.downloadedBytes),
            formattedBytes(point.uploadedBytes)
        )
    }

    private func appRow(_ app: NetworkAppTrafficSnapshot) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedAppIDs.contains(app.id) },
            set: { isExpanded in
                if isExpanded { expandedAppIDs.insert(app.id) }
                else { expandedAppIDs.remove(app.id) }
            }
        )) {
            processDetails(app)
        } label: {
            HStack(spacing: 10) {
                appIcon(app)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.appName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if app.isHistoricalOnly {
                            Text(L("traffic.historical"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(L(app.identity.kind.titleKey))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                miniTrend(app)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("↓ \(formattedRate(app.downloadBytesPerSecond))  ↑ \(formattedRate(app.uploadBytesPerSecond))")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                    Text("↓ \(formattedBytes(app.sessionDownloadedBytes))  ↑ \(formattedBytes(app.sessionUploadedBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func miniTrend(_ app: NetworkAppTrafficSnapshot) -> some View {
        let points = NetworkTrafficHistorySeries.make(
            from: service.snapshot.history,
            range: .hour,
            now: Date(),
            appIDs: [app.id]
        )
        let bytes = points.map(\.bytes)

        return Canvas { context, size in
            let bars = NetworkTrafficMiniTrendLayout.barFrames(bytes: bytes, size: size)
            for (index, bar) in bars.enumerated() {
                context.fill(
                    Path(bar),
                    with: .color(.teal.opacity(bytes[index] == 0 ? 0.16 : 0.7))
                )
            }
        }
        .frame(width: 50, height: 22, alignment: .bottom)
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func processDetails(_ app: NetworkAppTrafficSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let bundleIdentifier = app.identity.bundleIdentifier {
                detailLine(L("traffic.bundleID"), bundleIdentifier)
            }
            if let bundlePath = app.identity.bundlePath {
                detailLine(L("traffic.path"), bundlePath)
            }
            if app.processes.isEmpty {
                Text(L(app.isHistoricalOnly ? "traffic.historicalOnly" : "traffic.noProcessDetails"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("traffic.processes"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(app.processes) { process in
                    HStack {
                        Text("\(process.processName) (PID \(process.pid))")
                            .font(.caption2)
                            .lineLimit(1)
                        Spacer()
                        Text("↓ \(formattedRate(process.downloadBytesPerSecond))  ↑ \(formattedRate(process.uploadBytesPerSecond))")
                            .font(.caption2)
                            .monospacedDigit()
                    }
            }

            HStack {
                Text(L("traffic.connections"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if service.isLoadingConnections(for: app.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    let buttonKey = service.connectionLoadError(for: app.id) == nil
                        ? (service.hasLoadedConnections(for: app.id)
                            ? "traffic.reloadConnections"
                            : "traffic.loadConnections")
                        : "traffic.retry"
                    Button(L(buttonKey)) {
                        service.loadConnections(for: app.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                }
            }
            if let error = service.connectionLoadError(for: app.id) {
                Label(connectionErrorTitle(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if service.hasLoadedConnections(for: app.id) {
                if app.connections.isEmpty {
                    Text(L("traffic.noConnections"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(app.connections) { connection in
                        HStack(spacing: 6) {
                            Text(connection.transport.rawValue.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L(
                                    "traffic.remoteEndpoint",
                                    formattedEndpoint(
                                        host: connection.components.host,
                                        port: connection.components.port
                                    )
                                ))
                                    .font(.caption2)
                                    .lineLimit(1)
                                if let localHost = connection.components.localHost {
                                    Text(L(
                                        "traffic.localEndpoint",
                                        formattedEndpoint(
                                            host: localHost,
                                            port: connection.components.localPort
                                        )
                                    ))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            .textSelection(.enabled)
                            Spacer()
                            Text("↓ \(formattedBytes(connection.downloadedBytes))  ↑ \(formattedBytes(connection.uploadedBytes))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Button {
                                copyEndpoint(connection.endpoint)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help(L("traffic.copyEndpoint"))
                            .accessibilityLabel(L("traffic.copyEndpoint"))
                        }
                    }
                }
            }
        }
        }
        .padding(.leading, 34)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func appIcon(_ app: NetworkAppTrafficSnapshot) -> some View {
        if let bundlePath = app.identity.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: app.identity.kind == .systemService ? "gearshape.2" : "app.dashed")
                .foregroundStyle(.tint)
        }
    }

    private var footerActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("traffic.exportPrivacy"))
                    .foregroundStyle(.secondary)
                Picker(L("traffic.exportPrivacy"), selection: $exportPrivacy) {
                    ForEach(NetworkTrafficExportPrivacy.allCases, id: \.self) { privacy in
                        Text(L(privacy.titleKey)).tag(privacy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text(L("traffic.exportPrivacy.description"))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)

            HStack(spacing: 12) {
            Menu {
                Button(L("traffic.exportCSV")) {
                    exportCSV(snapshot: visibleExportSnapshot, nameSuffix: "Current")
                }
                Button(L("traffic.exportHistory")) {
                    exportHistoryCSV(snapshot: visibleExportSnapshot, nameSuffix: "Current")
                }
                Button(L("traffic.exportJSON")) {
                    exportJSON(snapshot: visibleExportSnapshot, nameSuffix: "Current")
                }
            } label: {
                Label(L("traffic.exportCurrent"), systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)

            Menu {
                Button(L("traffic.exportAllCSV")) {
                    exportCSV(snapshot: service.snapshot, nameSuffix: "All")
                }
                Button(L("traffic.exportAllHistory")) {
                    exportHistoryCSV(snapshot: service.snapshot, nameSuffix: "All")
                }
                Button(L("traffic.exportAllJSON")) {
                    exportJSON(snapshot: service.snapshot, nameSuffix: "All")
                }
            } label: {
                Label(L("traffic.exportAll"), systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)

            Spacer()

            Button(role: .destructive) {
                showingClearHistory = true
            } label: {
                Label(L("traffic.clearHistory"), systemImage: "trash")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                showingClearAllHistory = true
            } label: {
                Label(L("traffic.clearAllHistory"), systemImage: "trash.slash")
            }
            .buttonStyle(.borderless)
            }
        }
        .font(.caption)
    }

    private var visibleExportSnapshot: NetworkTrafficSnapshot {
        NetworkTrafficExportSelection.make(
            snapshot: service.snapshot,
            appIDs: visibleAppIDs,
            range: historyRange,
            now: Date()
        )
    }

    private func statusBanner(title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.1), in: .rect(cornerRadius: 8))
    }

    private var networkErrorBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label(unavailableTitle, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button {
                    Task { @MainActor in
                        await service.refresh()
                    }
                } label: {
                    Label(L("traffic.retry"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            if service.consecutiveSampleFailures > 1 {
                Text(L("traffic.error.attempts", service.consecutiveSampleFailures))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 8))
    }

    private var unavailableTitle: String {
        switch service.snapshot.status {
        case .commandUnavailable: return L("traffic.error.commandUnavailable")
        case .permissionDenied: return L("traffic.error.permissionDenied")
        case .malformedOutput: return L("traffic.error.malformedOutput")
        case .commandFailed: return L("traffic.error.commandFailed")
        case .timedOut: return L("traffic.error.timedOut")
        case .available: return L("traffic.unavailable")
        }
    }

    private func connectionErrorTitle(_ status: NetworkTrafficReadStatus) -> String {
        L("traffic.connectionLoadFailed", statusTitle(status))
    }

    private func statusTitle(_ status: NetworkTrafficReadStatus) -> String {
        switch status {
        case .commandUnavailable: return L("traffic.error.commandUnavailable")
        case .permissionDenied: return L("traffic.error.permissionDenied")
        case .malformedOutput: return L("traffic.error.malformedOutput")
        case .commandFailed: return L("traffic.error.commandFailed")
        case .timedOut: return L("traffic.error.timedOut")
        case .available: return L("traffic.unavailable")
        }
    }

    private func formattedEndpoint(host: String, port: Int?) -> String {
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return port.map { "\(formattedHost):\($0)" } ?? formattedHost
    }

    private func sortComparator(_ lhs: NetworkAppTrafficSnapshot, _ rhs: NetworkAppTrafficSnapshot) -> Bool {
        switch sort {
        case .activity:
            if lhs.currentBytesPerSecond != rhs.currentBytesPerSecond {
                return lhs.currentBytesPerSecond > rhs.currentBytesPerSecond
            }
        case .total:
            let left = NetworkTrafficMath.clampedAdd(lhs.sessionDownloadedBytes, lhs.sessionUploadedBytes)
            let right = NetworkTrafficMath.clampedAdd(rhs.sessionDownloadedBytes, rhs.sessionUploadedBytes)
            if left != right { return left > right }
        case .name:
            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        case .download:
            if lhs.downloadBytesPerSecond != rhs.downloadBytesPerSecond {
                return lhs.downloadBytesPerSecond > rhs.downloadBytesPerSecond
            }
        case .upload:
            if lhs.uploadBytesPerSecond != rhs.uploadBytesPerSecond {
                return lhs.uploadBytesPerSecond > rhs.uploadBytesPerSecond
            }
        }
        return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
    }

    private func exportCSV(snapshot: NetworkTrafficSnapshot, nameSuffix: String) {
        let panel = NSSavePanel()
        panel.title = L("traffic.exportCSV")
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "MenuTools-NetworkTraffic-\(nameSuffix).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try NetworkTrafficExporter.csv(exportSnapshot(snapshot)).write(to: url, atomically: true, encoding: .utf8)
            exportMessage = L("traffic.exportSuccess")
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportJSON(snapshot: NetworkTrafficSnapshot, nameSuffix: String) {
        let panel = NSSavePanel()
        panel.title = L("traffic.exportJSON")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MenuTools-NetworkTraffic-\(nameSuffix).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try NetworkTrafficExporter.json(exportSnapshot(snapshot)).write(to: url, options: .atomic)
            exportMessage = L("traffic.exportSuccess")
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportHistoryCSV(snapshot: NetworkTrafficSnapshot, nameSuffix: String) {
        let panel = NSSavePanel()
        panel.title = L("traffic.exportHistory")
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "MenuTools-NetworkTraffic-History-\(nameSuffix).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try NetworkTrafficExporter.historyCSV(exportSnapshot(snapshot))
                .write(to: url, atomically: true, encoding: .utf8)
            exportMessage = L("traffic.exportSuccess")
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportSnapshot(_ snapshot: NetworkTrafficSnapshot) -> NetworkTrafficSnapshot {
        NetworkTrafficExportSanitizer.make(snapshot, privacy: exportPrivacy)
    }

    private func copyEndpoint(_ endpoint: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint, forType: .string)
        exportMessage = L("traffic.endpointCopied")
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .binary)
    }

    private func formattedRate(_ value: Int64) -> String {
        "\(formattedBytes(value))/s"
    }
}
