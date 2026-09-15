import AppKit
import SwiftUI

/// 系统资源设置页的一级页面。
enum SystemResourceSettingsPage: String, CaseIterable, Identifiable {
    case overview
    case processes

    var id: Self { self }
    var titleKey: String { "resource.page.\(rawValue)" }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .processes: "list.bullet.rectangle"
        }
    }
}

/// 系统资源模块的设置页：概览与进程排行。
///
/// 采样随页面存续：进入即开始，离开（task 取消）即停止，符合分级采样策略。
struct SystemResourceSettingsView: View {
    @State private var resource = SystemResourceService.shared
    @State private var processes = SystemProcessResourceService.shared
    @State private var page: SystemResourceSettingsPage = .overview
    @State private var isReleasingMemory = false

    var body: some View {
        Form {
            Section {
                Picker(L("resource.page.title"), selection: $page) {
                    ForEach(SystemResourceSettingsPage.allCases) { item in
                        Label(L(item.titleKey), systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .focusable(false)
                .focusEffectDisabled()
            }

            if page == .overview {
                overviewSections
                alertSection
            } else {
                processSections
            }
        }
        .formStyle(.grouped)
        .task {
            resource.beginMonitoring()
            processes.beginMonitoring()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
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

                if snapshot.memoryPressure.shouldOfferMemoryRelease {
                    Button {
                        guard !isReleasingMemory else { return }
                        isReleasingMemory = true
                        _ = resource.releaseMemory()
                        isReleasingMemory = false
                    } label: {
                        Label(
                            resource.isReleasingMemory ? L("resource.releasingMemory") : L("resource.releaseMemory"),
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(resource.isReleasingMemory)
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
