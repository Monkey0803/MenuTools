import Foundation

/// 自检结论。
enum SystemResourceSelfCheckStatus: String, Equatable, Sendable {
    case ok
    case warning
    case failed

    var titleKey: String { "resource.selfCheck.status.\(rawValue)" }
    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

/// 自检的一步。
struct SystemResourceSelfCheckStep: Identifiable, Equatable, Sendable {
    let id: String
    let titleKey: String
    let status: SystemResourceSelfCheckStatus
    /// 具体数值信息（如核心数、库体积）。
    let detail: String?
    /// 处理建议（失败/警告时给出）。
    let adviceKey: String?
}

/// 资源数据源自检：按「取数 → 进程 → 历史 → 采样 → 通知」逐步给出结论。
enum SystemResourceSelfCheck {
    static func steps(
        snapshot: SystemResourceSnapshot?,
        isMonitoring: Bool,
        samplingInterval: TimeInterval?,
        processCount: Int,
        historyCount: Int,
        historyStorageBytes: Int64,
        alertsEnabled: Bool,
        notificationPermission: SystemResourceNotificationPermission
    ) -> [SystemResourceSelfCheckStep] {
        var steps: [SystemResourceSelfCheckStep] = []

        // 1. CPU 与内存（含每核）
        if let snapshot, snapshot.memoryTotalBytes > 0 {
            let cores = snapshot.coreUsages.count
            steps.append(SystemResourceSelfCheckStep(
                id: "cpu",
                titleKey: "resource.selfCheck.cpu",
                status: cores > 1 ? .ok : .warning,
                detail: cores > 1
                    ? "\(L("resource.selfCheck.cores", cores)) · \(percent(snapshot.cpuUsage))"
                    : percent(snapshot.cpuUsage),
                adviceKey: cores > 1 ? nil : "resource.selfCheck.cpu.advice"
            ))
        } else {
            steps.append(SystemResourceSelfCheckStep(
                id: "cpu",
                titleKey: "resource.selfCheck.cpu",
                status: .failed,
                detail: nil,
                adviceKey: "resource.selfCheck.cpu.advice"
            ))
        }

        // 2. 磁盘容量
        if let snapshot, snapshot.diskTotalBytes > 0 {
            steps.append(SystemResourceSelfCheckStep(
                id: "disk",
                titleKey: "resource.selfCheck.disk",
                status: .ok,
                detail: "\(bytes(snapshot.diskAvailableBytes)) / \(bytes(snapshot.diskTotalBytes))",
                adviceKey: nil
            ))
        } else {
            steps.append(SystemResourceSelfCheckStep(
                id: "disk",
                titleKey: "resource.selfCheck.disk",
                status: .failed,
                detail: nil,
                adviceKey: "resource.selfCheck.disk.advice"
            ))
        }

        // 3. 进程列表
        steps.append(SystemResourceSelfCheckStep(
            id: "process",
            titleKey: "resource.selfCheck.process",
            status: processCount > 0 ? .ok : .warning,
            detail: "\(processCount)",
            adviceKey: processCount > 0 ? nil : "resource.selfCheck.process.advice"
        ))

        // 4. 历史库
        let hasHistory = historyCount > 0 || historyStorageBytes > 0
        steps.append(SystemResourceSelfCheckStep(
            id: "history",
            titleKey: "resource.selfCheck.history",
            status: hasHistory ? .ok : .warning,
            detail: hasHistory
                ? "\(historyCount) · \(bytes(historyStorageBytes))"
                : nil,
            adviceKey: hasHistory ? nil : "resource.selfCheck.history.advice"
        ))

        // 5. 采样档位
        if isMonitoring, let samplingInterval {
            steps.append(SystemResourceSelfCheckStep(
                id: "sampling",
                titleKey: "resource.selfCheck.sampling",
                status: .ok,
                detail: "\(Int(samplingInterval))s",
                adviceKey: nil
            ))
        } else {
            steps.append(SystemResourceSelfCheckStep(
                id: "sampling",
                titleKey: "resource.selfCheck.sampling",
                status: .warning,
                detail: nil,
                adviceKey: "resource.selfCheck.sampling.advice"
            ))
        }

        // 6. 通知授权（未开启告警时只作说明）
        let permission: SystemResourceSelfCheckStatus
        switch (alertsEnabled, notificationPermission) {
        case (false, _): permission = .ok
        case (true, .authorized): permission = .ok
        case (true, .notRequested): permission = .warning
        case (true, .denied): permission = .failed
        }
        steps.append(SystemResourceSelfCheckStep(
            id: "notification",
            titleKey: "resource.selfCheck.notification",
            status: permission,
            detail: alertsEnabled ? nil : L("resource.selfCheck.notification.off"),
            adviceKey: permission == .ok ? nil : "resource.selfCheck.notification.advice"
        ))

        // 7. 可选指标（温度 / GPU）：硬件与系统决定是否可得，因此只作说明不作告警
        let gpu = snapshot?.gpuUsage
        let temperature = snapshot?.temperatureCelsius
        let optionalDetail: String?
        switch (gpu, temperature) {
        case let (.some(gpu), .some(temperature)):
            optionalDetail = "\(percent(gpu)) · \(Int(temperature.rounded()))°C"
        case let (.some(gpu), .none):
            optionalDetail = "\(percent(gpu)) · \(L("resource.selfCheck.optional.noTemperature"))"
        case let (.none, .some(temperature)):
            optionalDetail = "\(Int(temperature.rounded()))°C · \(L("resource.selfCheck.optional.noGPU"))"
        case (.none, .none):
            optionalDetail = L("resource.selfCheck.optional.unavailable")
        }
        steps.append(SystemResourceSelfCheckStep(
            id: "optional",
            titleKey: "resource.selfCheck.optional",
            status: .ok,
            detail: optionalDetail,
            adviceKey: nil
        ))

        return steps
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((min(max(value.isFinite ? value : 0, 0), 1) * 100).rounded()))%"
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .memory)
    }
}
