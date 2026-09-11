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

enum WindowSnapPreviewPlanner {
    /// 根据鼠标位置推导将要吸附的布局与落点；不在任何吸附区域时返回 nil。
    static func plan(
        for point: CGPoint,
        screens: [WindowSnapScreen],
        options: WindowManagerOptions
    ) -> WindowSnapPreviewPlan? {
        guard let index = WindowSnapResolver.screenIndex(
            for: point,
            screens: screens.map(\.frame)
        ) else { return nil }

        let screen = screens[index]
        guard let layout = WindowSnapResolver.layout(
            for: point,
            in: screen.frame,
            threshold: options.snapDistance
        ) else { return nil }

        return WindowSnapPreviewPlan(
            layout: layout,
            screenIndex: index,
            frame: WindowLayoutCalculator.frame(
                for: layout,
                in: screen.visibleFrame,
                options: options
            )
        )
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
