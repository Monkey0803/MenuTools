import AppKit
import Foundation

/// 拖拽吸附链路依赖的外部环境。
///
/// 这条链路原先直接读 `NSEvent.mouseLocation`、真实监听和 AX 元素，导致「预览为什么不出现」
/// 这类问题只能用真人拖拽加生产日志排查（macOS 26 又屏蔽了合成鼠标事件，脚本也替不了）。
/// 把这些外部依赖收敛成一组闭包后，单测可以用假实现驱动完整的按下 → 拖动 → 松手序列。
@MainActor
struct WindowDragEnvironment {
    /// 拖拽目标窗口的句柄：`handle` 由环境实现自行解释（生产实现里是 AX 元素）。
    struct Target {
        let handle: AnyObject
        let bundleIdentifier: String
    }

    var pointerLocation: () -> CGPoint
    var uptime: () -> TimeInterval
    var isOptionPressed: () -> Bool
    var showPreview: (WindowSnapPreviewPlan, CGRect?) -> Void
    var hidePreview: () -> Void
    var isPreviewVisible: () -> Bool
    var performHapticFeedback: () -> Void
    /// 命中测试：返回指针下的窗口；取不到返回 nil。
    var captureTarget: (CGPoint) -> Target?
    /// 目标窗口当前的 Cocoa 帧（可能滞后于视觉位置，生产实现直接读 AX）。
    var targetFrame: (Target) -> CGRect?
    /// 把帧写回目标窗口，返回是否成功。
    var setTargetFrame: (CGRect, Target) -> Bool

    /// 生产实现：接到真实指针、真实预览面板、真实 AX 元素上。
    static func live(service: WindowManagementService) -> WindowDragEnvironment {
        WindowDragEnvironment(
            pointerLocation: { NSEvent.mouseLocation },
            uptime: { ProcessInfo.processInfo.systemUptime },
            isOptionPressed: { NSEvent.modifierFlags.contains(.option) },
            showPreview: { plan, initialFrame in
                service.presentSnapPreview(plan, initialFrame: initialFrame)
            },
            hidePreview: { service.hideDragSnapPreview() },
            isPreviewVisible: { service.dragSnapPreviewIsVisible },
            performHapticFeedback: {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            },
            captureTarget: { service.captureDragTarget(at: $0) },
            targetFrame: { service.dragTargetFrame($0) },
            setTargetFrame: { service.setDragTargetFrame($0, target: $1) }
        )
    }
}
