import CoreGraphics
import Foundation

/// 同一布局连按时的同族循环序列。
///
/// 语义对齐 Rectangle：重复执行「第一列三分之一」会在三分之间轮换（第一 → 中间 → 最后一列），
/// 反向布局同理。半屏、角落、居中和移动类布局不参与循环，保持单次触发的确定性。
enum WindowLayoutCycle {
    private static let chains: [[WindowLayout]] = [
        [.firstThird, .centerThird, .lastThird],
        [.topThird, .middleThird, .bottomThird],
        [.firstTwoThirds, .lastTwoThirds],
        [.firstThreeFourths, .lastThreeFourths],
        [.firstFourth, .secondFourth, .thirdFourth, .lastFourth],
        [.topFirstFourth, .topSecondFourth, .topThirdFourth, .topLastFourth],
        [.topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth]
    ]

    /// 布局所属的循环链；不参与循环时返回 nil。
    static func chain(containing layout: WindowLayout) -> [WindowLayout]? {
        chains.first { $0.contains(layout) }
    }

    /// 返回同族中的下一个布局；不参与循环时返回 nil。
    static func next(after layout: WindowLayout) -> WindowLayout? {
        guard let chain = chain(containing: layout),
              let index = chain.firstIndex(of: layout) else { return nil }
        return chain[(index + 1) % chain.count]
    }
}

/// 记录「用户按下的布局」与「上一次实际应用的布局」，让连按同一快捷键在同族内推进。
///
/// 目标（应用 + 窗口）变化、或中途按下别的布局时，循环链重新开始，避免切换到别的窗口后
/// 继续沿用上一个窗口的进度。
struct WindowLayoutCycleState: Equatable {
    private var targetKey: String?
    private var requestedLayout: WindowLayout?
    private var appliedLayout: WindowLayout?

    mutating func nextLayout(requested: WindowLayout, targetKey: String) -> WindowLayout {
        guard targetKey == self.targetKey,
              requestedLayout == requested,
              let appliedLayout,
              let next = WindowLayoutCycle.next(after: appliedLayout) else {
            self.targetKey = targetKey
            requestedLayout = requested
            appliedLayout = requested
            return requested
        }
        self.appliedLayout = next
        return next
    }

    mutating func reset() {
        targetKey = nil
        requestedLayout = nil
        appliedLayout = nil
    }
}

/// 方向键挪动窗口的距离换算。
enum WindowNudge {
    /// 按住 Option 时的精调倍数分母。
    static let fineDivisor: CGFloat = 5

    static func offset(step: CGFloat, isFine: Bool) -> CGFloat {
        let base = max(1, step)
        guard isFine else { return base }
        return max(1, (base / fineDivisor).rounded())
    }
}
