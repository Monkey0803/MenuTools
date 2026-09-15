import Foundation

/// 菜单栏显示内容：跨模块的统一选择器。
///
/// `.automatic` 表示沿用各模块自己的设置（网速优先、其次音量），
/// 其余取值互斥地指定唯一来源，避免多个模块同时往菜单栏写标题。
enum MenuBarMetric: String, CaseIterable, Equatable, Hashable, Sendable {
    case automatic
    case networkSpeed
    case volume
    case cpu
    case memory
    case disk
    case off

    var titleKey: String { "menubar.metric.\(rawValue)" }

    /// 详情页里的说明文案。
    var footerKey: String? {
        self == .automatic ? "menubar.metric.automatic.footer" : nil
    }
}

/// 统一选择器与各模块设置的合并规则（纯函数，便于回归）。
enum MenuBarMetricResolver {
    /// - Parameters:
    ///   - unified: 统一选择器；nil 视为 `.automatic`
    ///   - trafficModeOff: 网络流量的模块内模式是否为关闭
    ///   - volumeModeOff: 音量的模块内模式是否为关闭
    static func resolve(
        unified: MenuBarMetric?,
        trafficModeOff: Bool,
        volumeModeOff: Bool
    ) -> MenuBarMetric {
        switch unified ?? .automatic {
        case .automatic:
            if !trafficModeOff { return .networkSpeed }
            if !volumeModeOff { return .volume }
            return .off
        case let explicit:
            return explicit
        }
    }
}

/// 资源指标在菜单栏上的标题。
enum SystemResourceMenuBarPresenter {
    /// 百分比固定三位宽（如 "  5%"、" 42%"、"100%"），避免菜单栏标题宽度变化带动弹窗抖动。
    static func percent(_ value: Double) -> String {
        let clamped = min(max(value.isFinite ? value : 0, 0), 1)
        return String(format: "%3d%%", Int((clamped * 100).rounded()))
    }

    /// 只有选择 CPU / 内存 / 磁盘时才产出标题；其余情况返回 nil。
    static func title(snapshot: SystemResourceSnapshot?, metric: MenuBarMetric) -> String? {
        guard let snapshot else { return nil }
        switch metric {
        case .cpu:
            return "\(L("menubar.metric.cpu")) \(percent(snapshot.cpuUsage))"
        case .memory:
            let usage = snapshot.memoryTotalBytes > 0
                ? Double(snapshot.memoryUsedBytes) / Double(snapshot.memoryTotalBytes)
                : 0
            return "\(L("menubar.metric.memory")) \(percent(usage))"
        case .disk:
            // 磁盘显示「已用容量占比」，与 CPU/内存的口径一致。
            let usage = snapshot.diskTotalBytes > 0
                ? 1 - Double(max(snapshot.diskAvailableBytes, 0)) / Double(snapshot.diskTotalBytes)
                : 0
            return "\(L("menubar.metric.disk")) \(percent(usage))"
        case .automatic, .networkSpeed, .volume, .off:
            return nil
        }
    }
}
