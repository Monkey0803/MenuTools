import Foundation

/// 自检步骤的结论。
enum AppVolumeSelfCheckStatus: String, Sendable {
    case pass
    case warning
    case failure

    var symbolName: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }
}

/// 一步自检：权限 → 输出设备 → 输入设备 → 路由 → 错误。
struct AppVolumeSelfCheckStep: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case permission
        case output
        case input
        case routing
        case errors
    }

    var kind: Kind
    var status: AppVolumeSelfCheckStatus
    /// 已本地化的细节说明。
    var detail: String

    var id: String { kind.rawValue }
    var titleKey: String { "volume.selfCheck.step.\(kind.rawValue)" }
}

/// 音量模块的自检：把权限、设备与路由状态整理成可读的排查步骤。
///
/// 纯函数，便于回归；界面直接把当前状态喂进来即可实时刷新。
enum AppVolumeSelfCheck {
    static func steps(
        permission: AppVolumePermissionState,
        outputReady: Bool,
        inputReady: Bool,
        activeSessions: Int,
        routedSessions: Int,
        failedSessions: Int,
        hasError: Bool
    ) -> [AppVolumeSelfCheckStep] {
        [
            permissionStep(permission),
            AppVolumeSelfCheckStep(
                kind: .output,
                status: outputReady ? .pass : .failure,
                detail: outputReady ? L("volume.selfCheck.output.ready") : L("volume.selfCheck.output.missing")
            ),
            AppVolumeSelfCheckStep(
                kind: .input,
                status: inputReady ? .pass : .warning,
                detail: inputReady ? L("volume.selfCheck.input.ready") : L("volume.selfCheck.input.missing")
            ),
            routingStep(
                activeSessions: activeSessions,
                routedSessions: routedSessions,
                failedSessions: failedSessions
            ),
            AppVolumeSelfCheckStep(
                kind: .errors,
                status: hasError ? .warning : .pass,
                detail: hasError ? L("volume.selfCheck.errors.present") : L("volume.selfCheck.errors.clear")
            )
        ]
    }

    private static func permissionStep(_ permission: AppVolumePermissionState) -> AppVolumeSelfCheckStep {
        switch permission {
        case .authorized:
            AppVolumeSelfCheckStep(
                kind: .permission,
                status: .pass,
                detail: L("volume.selfCheck.permission.authorized")
            )
        case .notRequested:
            AppVolumeSelfCheckStep(
                kind: .permission,
                status: .warning,
                detail: L("volume.selfCheck.permission.notRequested")
            )
        case .denied:
            AppVolumeSelfCheckStep(
                kind: .permission,
                status: .failure,
                detail: L("volume.selfCheck.permission.denied")
            )
        }
    }

    private static func routingStep(
        activeSessions: Int,
        routedSessions: Int,
        failedSessions: Int
    ) -> AppVolumeSelfCheckStep {
        if failedSessions > 0 {
            return AppVolumeSelfCheckStep(
                kind: .routing,
                status: .failure,
                detail: L("volume.selfCheck.routing.failed", failedSessions)
            )
        }
        if activeSessions == 0 {
            return AppVolumeSelfCheckStep(
                kind: .routing,
                status: .warning,
                detail: L("volume.selfCheck.routing.idle")
            )
        }
        if routedSessions > 0 {
            return AppVolumeSelfCheckStep(
                kind: .routing,
                status: .pass,
                detail: L("volume.selfCheck.routing.active", routedSessions)
            )
        }
        return AppVolumeSelfCheckStep(
            kind: .routing,
            status: .pass,
            detail: L("volume.selfCheck.routing.bypassed")
        )
    }
}