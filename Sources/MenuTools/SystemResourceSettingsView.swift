import AppKit
import SwiftUI

/// 系统资源设置页的一级页面。
enum SystemResourceSettingsPage: String, CaseIterable, Identifiable {
    case overview
    case processes
    case history

    var id: Self { self }
    var titleKey: String { "resource.page.\(rawValue)" }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .processes: "list.bullet.rectangle"
        case .history: "chart.bar.xaxis"
        }
    }
}

/// 系统资源页的 Liquid Glass 视觉参数，集中管理以便保持设置页风格一致。
enum SystemResourceVisualPolicy {
    static let usesLiquidGlass = true
    static let containerSpacing: CGFloat = 10

    /// 页面切换只更新选中状态，不让动态 Form 参与隐式布局动画。
    static func selectionBinding(
        _ selection: Binding<SystemResourceSettingsPage>
    ) -> Binding<SystemResourceSettingsPage> {
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        return selection.transaction(transaction)
    }
}

/// 系统资源模块的设置页：概览与进程排行。
///
/// 采样随页面存续：进入即开始，离开（task 取消）即停止，符合分级采样策略。
struct SystemResourceSettingsView: View {
    @State private var resource = SystemResourceService.shared
    @State private var processes = SystemProcessResourceService.shared
    @State private var page: SystemResourceSettingsPage = .overview
    @State private var relieveMessage: String?
    @State private var purgeMessage: String?
    @State private var historyRange: SystemResourceHistoryRange = .hour
    @State private var historyMetric: SystemResourceHistoryMetric = .cpu
    @State private var hoveredHistoryIndex: Int?

    var body: some View {
        GlassEffectContainer(spacing: SystemResourceVisualPolicy.containerSpacing) {
            VStack(spacing: SystemResourceVisualPolicy.containerSpacing) {
                Picker(
                    L("resource.page.title"),
                    selection: SystemResourceVisualPolicy.selectionBinding($page)
                ) {
                    ForEach(SystemResourceSettingsPage.allCases) { item in
                        Label(L(item.titleKey), systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .focusable(false)
                .focusEffectDisabled()
                .glassEffect(
                    .regular
                        .tint(Color.accentColor.opacity(0.18)),
                    in: .rect(cornerRadius: 10)
                )

                Form {
                    Group {
                        switch page {
                        case .overview:
                            overviewSections
                            alertSection
                            selfCheckSection
                        case .processes:
                            processSections
                        case .history:
                            historySections
                        }
                    }
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task {
            resource.beginMonitoring()
            processes.beginMonitoring()
            resource.loadHistory()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                resource.loadHistory()
            }
            resource.endMonitoring()
            processes.endMonitoring()
        }
    }

    // MARK: - 概览

    @ViewBuilder
    private var overviewSections: some View {
        if let snapshot = resource.snapshot {
            Section {
                LabeledContent(L("resource.cpu"), value: percent(snapshot.cpuUsage))
                if snapshot.coreUsages.count > 1 {
                    coreBars(snapshot.coreUsages)
                }
            } header: {
                Label(L("resource.cpu"), systemImage: "cpu")
            }

            Section {
                LabeledContent(
                    L("resource.memory"),
                    value: "\(bytes(snapshot.memoryUsedBytes)) / \(bytes(snapshot.memoryTotalBytes))"
                )
                LabeledContent(L("resource.memory.pressure"), value: L(pressureKey(snapshot.memoryPressure)))

                if let detail = snapshot.memoryDetail {
                    memoryDetailRow(L("resource.memory.wired"), bytes: detail.wiredBytes, total: detail.totalBytes)
                    memoryDetailRow(L("resource.memory.active"), bytes: detail.activeBytes, total: detail.totalBytes)
                    memoryDetailRow(L("resource.memory.compressed"), bytes: detail.compressedBytes, total: detail.totalBytes)
                    memoryDetailRow(L("resource.memory.cached"), bytes: detail.cachedBytes, total: detail.totalBytes)
                    memoryDetailRow(L("resource.memory.free"), bytes: detail.freeBytes, total: detail.totalBytes)
                }

                Button {
                    let released = resource.relieveProcessMemory()
                    relieveMessage = released > 0
                        ? L("resource.relieveMemory.done", bytes(released))
                        : L("resource.relieveMemory.none")
                } label: {
                    Label(
                        resource.isReleasingMemory ? L("resource.releasingMemory") : L("resource.relieveMemory"),
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(resource.isReleasingMemory)
                if let relieveMessage {
                    Text(relieveMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // 需要管理员授权：与上面的免权限回收互不影响，取消也不会影响它。
                Button {
                    purgeMessage = resource.purgeSystemCache()
                        ? L("resource.purgeSystemCache.done")
                        : L("resource.purgeSystemCache.cancelled")
                } label: {
                    Label(L("resource.purgeSystemCache"), systemImage: "externaldrive.badge.checkmark")
                }
                Text(L("resource.purgeSystemCache.desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let purgeMessage {
                    Text(purgeMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label(L("resource.memory"), systemImage: "memorychip")
            }

            Section {
                LabeledContent(
                    L("resource.disk"),
                    value: "\(bytes(snapshot.diskAvailableBytes)) \(L("resource.free")) / \(bytes(snapshot.diskTotalBytes))"
                )
                LabeledContent(L("resource.disk.read"), value: rate(snapshot.diskReadBytesPerSecond))
                LabeledContent(L("resource.disk.write"), value: rate(snapshot.diskWriteBytesPerSecond))
            } header: {
                Label(L("resource.disk"), systemImage: "internaldrive")
            }

            if snapshot.temperatureCelsius != nil || snapshot.gpuUsage != nil {
                Section {
                    if let temperature = snapshot.temperatureCelsius {
                        LabeledContent(
                            L("resource.temperature"),
                            value: String(format: "%.0f °C", temperature)
                        )
                    }
                    if let gpu = snapshot.gpuUsage {
                        LabeledContent(L("resource.gpu"), value: percent(gpu))
                    }
                } header: {
                    Label(L("resource.optional.title"), systemImage: "thermometer.medium")
                }
            }

            Section {
                LabeledContent(L("resource.network.download"), value: rate(snapshot.networkDownloadBytesPerSecond))
                LabeledContent(L("resource.network.upload"), value: rate(snapshot.networkUploadBytesPerSecond))
            } header: {
                Label(L("resource.network"), systemImage: "arrow.up.arrow.down")
            }
        } else {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L("resource.loading"))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func coreBars(_ usages: [SystemResourceCoreUsage]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("resource.cores"))
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 6)], alignment: .leading, spacing: 4) {
                ForEach(usages, id: \.index) { core in
                    HStack(spacing: 4) {
                        Text("\(core.index)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, alignment: .trailing)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.primary.opacity(0.08))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(core.usage > 0.85 ? Color.orange : Color.accentColor)
                                    .frame(width: max(geometry.size.width * core.usage, 1))
                            }
                        }
                        .frame(height: 8)
                        Text("\(Int((core.usage * 100).rounded()))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func memoryDetailRow(_ title: String, bytes value: Int64, total: Int64) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(bytes(value))
                    .font(.caption.monospacedDigit())
                Text(percent(total == 0 ? 0 : Double(value) / Double(total)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 进程

    @ViewBuilder
    private var processSections: some View {
        Section {
            TextField(L("resource.process.search"), text: Binding(
                get: { processes.query.searchText },
                set: { processes.query.searchText = $0 }
            ))
            Picker(L("resource.process.sort"), selection: Binding(
                get: { processes.query.sort },
                set: { processes.query.sort = $0 }
            )) {
                ForEach(SystemProcessSort.allCases, id: \.self) { sort in
                    Text(L(sort.titleKey)).tag(sort)
                }
            }
        }

        Section {
            if processes.visibleUsages.isEmpty {
                Text(L("resource.process.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(processes.visibleUsages) { usage in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(usage.name)
                                .lineLimit(1)
                            Text(L("resource.process.pid", Int(usage.pid)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 8)
                        Text(percent(usage.cpuUsage))
                            .font(.caption.monospacedDigit())
                            .frame(width: 52, alignment: .trailing)
                        Text(bytes(usage.memoryBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 76, alignment: .trailing)
                        Text("\(rate(usage.diskReadBytesPerSecond)) / \(rate(usage.diskWrittenBytesPerSecond))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 120, alignment: .trailing)
                    }
                }
            }
        } header: {
            Label(L("resource.process.title"), systemImage: "list.bullet.rectangle")
        }
    }

    // MARK: - 自检

    private var selfCheckSteps: [SystemResourceSelfCheckStep] {
        SystemResourceSelfCheck.steps(
            snapshot: resource.snapshot,
            isMonitoring: resource.isMonitoring,
            samplingInterval: resource.currentSamplingInterval,
            processCount: processes.usages.count,
            historyCount: resource.historyBuckets.count,
            historyStorageBytes: resource.historyStorageUsage.totalBytes,
            alertsEnabled: resource.alertsEnabled,
            notificationPermission: resource.notificationPermission
        )
    }

    @ViewBuilder
    private var selfCheckSection: some View {
        Section {
            ForEach(selfCheckSteps) { step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: step.status.symbol)
                        .foregroundStyle(statusColor(step.status))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L(step.titleKey))
                        if let adviceKey = step.adviceKey {
                            Text(L(adviceKey))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if let detail = step.detail {
                        Text(detail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Label(L("resource.selfCheck.title"), systemImage: "stethoscope")
        }
    }

    private func statusColor(_ status: SystemResourceSelfCheckStatus) -> Color {
        switch status {
        case .ok: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }

    // MARK: - 历史

    @ViewBuilder
    private var historySections: some View {
        Section {
            Picker(L("resource.history.range"), selection: $historyRange) {
                ForEach(SystemResourceHistoryRange.allCases, id: \.self) { range in
                    Text(L(range.titleKey)).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker(L("resource.history.metric"), selection: $historyMetric) {
                ForEach(SystemResourceHistoryMetric.allCases, id: \.self) { metric in
                    Text(L(metric.titleKey)).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        Section {
            if historyBuckets.isEmpty {
                Text(L("resource.history.empty"))
                    .foregroundStyle(.secondary)
            } else {
                historyChart
                LabeledContent(L("resource.history.average"), value: historyAverageText)
                LabeledContent(L("resource.history.peak"), value: historyPeakText)
            }
        } header: {
            Label(L("resource.history.title"), systemImage: "chart.bar.xaxis")
        }

        Section {
            LabeledContent(L("resource.history.storage"), value: bytes(resource.historyStorageUsage.totalBytes))
            Button(L("resource.history.clear"), role: .destructive) {
                resource.clearHistory()
            }
            .disabled(resource.historyBuckets.isEmpty && resource.historyStorageUsage.totalBytes == 0)
        }
    }

    private var historyChart: some View {
        let buckets = historyBuckets
        let values = buckets.map { historyMetric.value(of: $0) }
        let maximum = max(values.max() ?? 1, historyMetric.isRatio ? 1 : 0.0001)
        let hovered = hoveredHistoryIndex.flatMap { $0 < buckets.count ? buckets[$0] : nil }

        return VStack(alignment: .leading, spacing: 6) {
            Group {
                if let hovered {
                    historyHoverDetail(hovered)
                } else {
                    Text(historyAverageText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 18)

            GeometryReader { geometry in
                let layout = SystemResourceHistoryChartLayout.barLayout(
                    totalWidth: geometry.size.width,
                    sampleCount: buckets.count
                )
                HStack(alignment: .bottom, spacing: layout.spacing) {
                    ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(historyBarColor(index: index))
                            .frame(
                                width: layout.width,
                                height: max(geometry.size.height * (values[index] / maximum), 1)
                            )
                            .opacity(hoveredHistoryIndex == nil || hoveredHistoryIndex == index ? 1 : 0.42)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .help(historyDetailText(bucket))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        let index = SystemResourceHistoryChartLayout.hoveredIndex(
                            x: location.x,
                            totalWidth: geometry.size.width,
                            sampleCount: buckets.count,
                            layout: layout
                        )
                        if index != hoveredHistoryIndex {
                            hoveredHistoryIndex = index
                        }
                    case .ended:
                        hoveredHistoryIndex = nil
                    }
                }
            }
            .frame(height: 96)
        }
    }

    private func historyBarColor(index: Int) -> Color {
        let buckets = historyBuckets
        guard buckets.indices.contains(index) else { return .accentColor }
        return historyMetric == .cpu && buckets[index].cpuUsage > 0.85 ? .orange : .accentColor
    }

    private func historyHoverDetail(_ bucket: SystemResourceHistoryBucket) -> some View {
        Text(historyDetailText(bucket))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// 悬停/提示详情：时间 + 同时给出 CPU、内存与磁盘读写。
    private func historyDetailText(_ bucket: SystemResourceHistoryBucket) -> String {
        let time = bucket.timestamp.formatted(date: .omitted, time: .shortened)
        let cpu = percent(bucket.cpuUsage)
        let memory = percent(bucket.memoryUsage)
        let disk = "\(rate(bucket.diskReadBytesPerSecond)) / \(rate(bucket.diskWriteBytesPerSecond))"
        let cpuLabel = L("resource.history.metric.cpu")
        let memoryLabel = L("resource.history.metric.memory")
        let diskLabel = L("resource.history.metric.disk")
        return "\(time)  \(cpuLabel) \(cpu)  \(memoryLabel) \(memory)  \(diskLabel) \(disk)"
    }

    private var historyBuckets: [SystemResourceHistoryBucket] {
        SystemResourceHistoryAggregator.aggregated(
            resource.historyBuckets,
            interval: historyRange.bucketInterval,
            since: Date().addingTimeInterval(-historyRange.duration)
        )
    }

    private var historyAverageText: String {
        let buckets = historyBuckets
        guard !buckets.isEmpty else { return "-" }
        let values = buckets.map { historyMetric.value(of: $0) }
        let average = values.reduce(0, +) / Double(values.count)
        return historyMetric.isRatio ? percent(average) : rate(Int64(average))
    }

    private var historyPeakText: String {
        let buckets = historyBuckets
        guard let peak = buckets.map({ historyMetric.value(of: $0) }).max() else { return "-" }
        return historyMetric.isRatio ? percent(peak) : rate(Int64(peak))
    }

    // MARK: - 告警

    @ViewBuilder
    private var alertSection: some View {
        Section {
            Toggle(L("resource.alert.enable"), isOn: Binding(
                get: { resource.alertsEnabled },
                set: { resource.setAlertsEnabled($0) }
            ))

            LabeledContent(L("resource.alert.permission")) {
                HStack(spacing: 8) {
                    Text(L(resource.notificationPermission.titleKey))
                        .foregroundStyle(resource.notificationPermission == .denied ? .orange : .secondary)
                    if resource.notificationPermission != .authorized {
                        Button(L("resource.alert.openSettings"), action: openNotificationSettings)
                    }
                }
            }

            if resource.alertsEnabled {
                LabeledContent(L("resource.alert.cpuThreshold")) {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { resource.alertThresholds.cpuUsage },
                            set: { updateThresholds(cpuUsage: $0) }
                        ), in: 0.5 ... 1)
                        .frame(width: 140)
                        Text(percent(resource.alertThresholds.cpuUsage))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Picker(L("resource.alert.cpuSustain"), selection: Binding(
                    get: { Int(resource.alertThresholds.cpuSustainDuration / 60) },
                    set: { updateThresholds(cpuSustainMinutes: $0) }
                )) {
                    ForEach([2, 5, 10, 15], id: \.self) { minutes in
                        Text(L("resource.alert.minutes", minutes)).tag(minutes)
                    }
                }

                LabeledContent(L("resource.alert.diskThreshold")) {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { resource.alertThresholds.diskFreeRatio },
                            set: { updateThresholds(diskFreeRatio: $0) }
                        ), in: 0.01 ... 0.3)
                        .frame(width: 140)
                        Text(percent(resource.alertThresholds.diskFreeRatio))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Label(L("resource.alert.section"), systemImage: "bell.badge")
        }
        .task {
            await resource.refreshNotificationPermission()
        }
    }

    private func updateThresholds(
        cpuUsage: Double? = nil,
        cpuSustainMinutes: Int? = nil,
        diskFreeRatio: Double? = nil
    ) {
        var thresholds = resource.alertThresholds
        if let cpuUsage { thresholds.cpuUsage = cpuUsage }
        if let cpuSustainMinutes { thresholds.cpuSustainDuration = TimeInterval(cpuSustainMinutes) * 60 }
        if let diskFreeRatio { thresholds.diskFreeRatio = diskFreeRatio }
        resource.setAlertThresholds(thresholds)
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 格式化

    private func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 99) * 100).rounded()))%"
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .memory)
    }

    private func rate(_ bytesPerSecond: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytesPerSecond, 0), countStyle: .binary) + "/s"
    }

    private func pressureKey(_ pressure: SystemMemoryPressure) -> String {
        switch pressure {
        case .normal: "resource.pressure.normal"
        case .warning: "resource.pressure.warning"
        case .critical: "resource.pressure.critical"
        }
    }
}
