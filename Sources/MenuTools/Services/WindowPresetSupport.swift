import CoreGraphics
import Foundation

/// 把预设记录的窗口帧夹取回可见区域。
///
/// 预设可能是几个月前在另一套显示器布局下保存的：显示器被拔掉、分辨率变化、主屏换边之后，
/// 原始坐标会落到屏幕外。这里只做最小平移（能不动就不动），尺寸超过可用区域时才压缩。
enum WindowFrameClamper {
    static func clamp(_ frame: CGRect, into visibleFrame: CGRect) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }

        let size = CGSize(
            width: min(frame.width, visibleFrame.width),
            height: min(frame.height, visibleFrame.height)
        )
        let origin = CGPoint(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
        return CGRect(origin: origin, size: size)
    }

    /// 先按重叠面积选出目标显示器（完全没有重叠时取最近的一台），再夹取到它的可用区域。
    static func clamp(_ frame: CGRect, into screens: [CGRect]) -> CGRect {
        guard let screen = targetScreen(for: frame, screens: screens) else { return frame }
        return clamp(frame, into: screen)
    }

    static func targetScreen(for frame: CGRect, screens: [CGRect]) -> CGRect? {
        guard !screens.isEmpty else { return nil }

        let overlaps = screens.map { screen -> (screen: CGRect, area: CGFloat) in
            let intersection = screen.intersection(frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            return (screen, area)
        }
        if let best = overlaps.max(by: { $0.area < $1.area }), best.area > 0 {
            return best.screen
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screens.min { lhs, rhs in
            hypot(lhs.midX - center.x, lhs.midY - center.y)
                < hypot(rhs.midX - center.x, rhs.midY - center.y)
        }
    }
}

/// 用当前窗口的尺寸创建固定尺寸预设。
enum WindowPresetFactory {
    static func preset(
        name: String,
        frame: CGRect,
        layout: WindowLayout = .centered
    ) -> WindowLayoutPreset? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        return WindowLayoutPreset(name: trimmedName, layout: layout, frame: frame)
    }
}

/// 连按半屏布局时把窗口带到相邻显示器（对标 Rectangle 的跨显示器遍历）。
enum WindowDisplayTraversal {
    /// 布局对应的显示器偏移方向；不参与跨显示器的布局返回 nil。
    static func displayOffset(for layout: WindowLayout) -> Int? {
        switch layout {
        case .leftHalf: return -1
        case .rightHalf, .topHalf, .bottomHalf: return 1
        default: return nil
        }
    }

    static func nextScreenIndex(current: Int, offset: Int, screenCount: Int) -> Int? {
        guard screenCount > 0, current >= 0, current < screenCount else { return nil }
        return ((current + offset) % screenCount + screenCount) % screenCount
    }
}

/// 判断本次触发是否是对「同一目标窗口的同一布局」的重复触发。
///
/// 循环布局和跨显示器都依赖这个判断：换了窗口或换了布局就重新开始，不会把上一个窗口的
/// 进度带过来。
struct WindowRepeatTracker: Equatable {
    private var targetKey: String?
    private var layout: WindowLayout?

    mutating func isRepeat(layout: WindowLayout, targetKey: String) -> Bool {
        let repeated = self.targetKey == targetKey && self.layout == layout
        self.targetKey = targetKey
        self.layout = layout
        return repeated
    }

    mutating func reset() {
        targetKey = nil
        layout = nil
    }
}
