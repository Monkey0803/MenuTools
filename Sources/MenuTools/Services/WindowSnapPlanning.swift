import CoreGraphics
import Foundation

/// 拖拽吸附时的预览落点。
struct WindowSnapPreviewPlan: Equatable, Sendable {
    let layout: WindowLayout
    let screenIndex: Int
    let frame: CGRect
}

/// 一台显示器：`frame` 用于判断鼠标落在哪块屏幕，`visibleFrame` 用于计算窗口落点。
///
/// 两者必须分开：菜单栏和程序坞覆盖的区域鼠标到得了（所以要参与命中判定），但不能把窗口放进去。
struct WindowSnapScreen: Equatable, Sendable {
    let frame: CGRect
    let visibleFrame: CGRect

    init(frame: CGRect, visibleFrame: CGRect? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
    }
}

extension WindowSnapResolver {
    /// 窗口边缘已经贴住屏幕边缘时的布局判定。
    ///
    /// 很多人是「把窗口推到屏幕边缘就松手」，此时光标离屏幕边缘可能还有几百点（抓标题栏的位置
    /// 离窗口左缘很远），只按光标判定会完全漏掉这种最自然的操作。
    static func layout(
        pressedWindowFrame frame: CGRect,
        in screen: CGRect,
        threshold: CGFloat
    ) -> WindowLayout? {
        guard screen.width > 0, screen.height > 0 else { return nil }

        // 用 2 倍阈值判断“几乎占满某个轴”：半屏窗口的高度其实已经接近屏幕高度
        //（只差屏幕边距），如果不排除，它的下边缘会被误判成“贴住屏幕下边缘”。
        let spansWidth = frame.width >= screen.width - threshold * 2
        let spansHeight = frame.height >= screen.height - threshold * 2
        // 最大化窗口四条边都贴着屏幕，没有方向信息。
        guard !(spansWidth && spansHeight) else { return nil }

        let nearLeft = !spansWidth && frame.minX <= screen.minX + threshold
        let nearRight = !spansWidth && frame.maxX >= screen.maxX - threshold
        let nearTop = !spansHeight && frame.maxY >= screen.maxY - threshold
        let nearBottom = !spansHeight && frame.minY <= screen.minY + threshold

        if nearTop && nearLeft { return .topLeft }
        if nearTop && nearRight { return .topRight }
        if nearBottom && nearLeft { return .bottomLeft }
        if nearBottom && nearRight { return .bottomRight }
        if nearTop { return .topHalf }
        if nearBottom { return .bottomHalf }
        if nearLeft { return .leftHalf }
        if nearRight { return .rightHalf }
        return nil
    }
}

enum WindowSnapPreviewPlanner {
    /// 推导将要吸附的布局与落点；不在任何吸附区域时返回 nil。
    ///
    /// 先按光标命中吸附带（能实时显示预览的那条路径），再回落到「被拖动窗口的边缘是否已经贴住
    /// 屏幕边缘」，覆盖「把窗口推到边缘就松手」这种光标离边缘还很远的操作。
    static func plan(
        for point: CGPoint,
        windowFrame: CGRect? = nil,
        screens: [WindowSnapScreen],
        options: WindowManagerOptions
    ) -> WindowSnapPreviewPlan? {
        if let index = WindowSnapResolver.screenIndex(for: point, screens: screens.map(\.frame)),
           let layout = WindowSnapResolver.layout(
               for: point,
               in: screens[index].frame,
               threshold: options.snapDistance
           ) {
            return WindowSnapPreviewPlan(
                layout: layout,
                screenIndex: index,
                frame: WindowLayoutCalculator.frame(
                    for: layout,
                    in: screens[index].visibleFrame,
                    options: options
                )
            )
        }

        guard let windowFrame,
              let index = screenIndex(for: windowFrame, screens: screens),
              let layout = WindowSnapResolver.layout(
                  pressedWindowFrame: windowFrame,
                  in: screens[index].frame,
                  threshold: options.snapDistance
              ) else { return nil }

        return WindowSnapPreviewPlan(
            layout: layout,
            screenIndex: index,
            frame: WindowLayoutCalculator.frame(
                for: layout,
                in: screens[index].visibleFrame,
                options: options
            )
        )
    }

    /// 与窗口重叠面积最大的显示器。
    static func screenIndex(for windowFrame: CGRect, screens: [WindowSnapScreen]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let overlaps = screens.enumerated().map { index, screen -> (index: Int, area: CGFloat) in
            let intersection = screen.frame.intersection(windowFrame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            return (index, area)
        }
        if let best = overlaps.max(by: { $0.area < $1.area }), best.area > 0 {
            return best.index
        }
        return screens.indices.min { lhs, rhs in
            hypot(screens[lhs].frame.midX - windowFrame.midX, screens[lhs].frame.midY - windowFrame.midY)
                < hypot(screens[rhs].frame.midX - windowFrame.midX, screens[rhs].frame.midY - windowFrame.midY)
        }
    }
}

/// 参与多窗口排列的候选窗口（由 AX 读出的最小信息）。
struct WindowArrangementCandidate: Equatable, Sendable {
    let frame: CGRect
    let isFullScreen: Bool
    let isMinimized: Bool

    init(frame: CGRect, isFullScreen: Bool, isMinimized: Bool) {
        self.frame = frame
        self.isFullScreen = isFullScreen
        self.isMinimized = isMinimized
    }

    var isManageable: Bool { !isFullScreen && !isMinimized }
}

enum WindowArrangementPolicy {
    /// 全屏和最小化的窗口不参与网格排列，否则会把它们从全屏空间里拽出来。
    static func manageableIndices(in candidates: [WindowArrangementCandidate]) -> [Int] {
        candidates.indices.filter { candidates[$0].isManageable }
    }

    /// 稳定的阅读顺序：先上后下，同一行内从左到右。
    ///
    /// 不能直接用「按 y 排序」的比较器：带容差的比较不满足传递性，会得到不稳定结果。
    /// 这里先按 top 边分组成行，再在行内按 x 排序。
    static func orderedIndices(
        in candidates: [WindowArrangementCandidate],
        rowTolerance: CGFloat = 40
    ) -> [Int] {
        var rows: [(top: CGFloat, indices: [Int])] = []
        for index in manageableIndices(in: candidates)
            .sorted(by: { candidates[$0].frame.maxY > candidates[$1].frame.maxY }) {
            let top = candidates[index].frame.maxY
            if let last = rows.indices.last, abs(rows[last].top - top) <= rowTolerance {
                rows[last].indices.append(index)
            } else {
                rows.append((top: top, indices: [index]))
            }
        }
        return rows.flatMap { row in
            row.indices.sorted { candidates[$0].frame.minX < candidates[$1].frame.minX }
        }
    }
}

/// 吸附落点变化时的触觉反馈判定。
///
/// 只在「进入新的落点区域」时响一次：拖动过程中同一个区域会反复命中，每个事件都震手会很烦。
enum WindowSnapFeedback {
    static func shouldTriggerHaptic(
        previous: WindowSnapPreviewPlan?,
        next: WindowSnapPreviewPlan?
    ) -> Bool {
        guard let next else { return false }
        guard let previous else { return true }
        return previous.layout != next.layout || previous.screenIndex != next.screenIndex
    }
}

/// 把已经吸附的窗口拖出来时，恢复吸附前的尺寸。
///
/// 对标 Rectangle 的 unsnap restore：左半屏/最大化的窗口被拖走时不应该还保持那块大尺寸。
enum WindowUnsnapCalculator {
    /// 尺寸差异小于该值视为「没有变化」，不做恢复。
    static let minimumSizeDelta: CGFloat = 2

    static func restoredFrame(
        current: CGRect,
        previous: CGRect,
        cursor: CGPoint,
        visibleFrame: CGRect
    ) -> CGRect? {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return nil }

        let size = CGSize(
            width: min(max(previous.width, 1), visibleFrame.width),
            height: min(max(previous.height, 1), visibleFrame.height)
        )
        guard abs(size.width - current.width) > minimumSizeDelta
            || abs(size.height - current.height) > minimumSizeDelta else { return nil }

        // 顶边保持不动（标题栏仍在光标下），水平方向按光标在窗口内的相对位置换算，
        // 这样光标不会因为窗口变窄而跑到窗口外面。
        let ratio = current.width > 0 ? (cursor.x - current.minX) / current.width : 0.5
        let proposedX = cursor.x - ratio * size.width
        let x = min(max(proposedX, visibleFrame.minX), visibleFrame.maxX - size.width)
        let top = min(max(current.maxY, visibleFrame.minY + size.height), visibleFrame.maxY)

        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }
}
