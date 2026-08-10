import CoreGraphics
import Testing
@testable import MenuTools

@Test("窗口布局支持左右分屏和四象限")
func windowLayoutCalculatesFrames() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    let left = WindowLayoutCalculator.frame(for: .leftHalf, in: screen)
    let topRight = WindowLayoutCalculator.frame(for: .topRight, in: screen)

    #expect(left.width < screen.width)
    #expect(left.height < screen.height)
    #expect(topRight.minX > screen.midX)
    #expect(topRight.minY > screen.midY)
}

@Test("窗口布局居中保留目标尺寸")
func windowLayoutCentersRequestedSize() {
    let screen = CGRect(x: 100, y: 80, width: 1200, height: 800)
    let frame = WindowLayoutCalculator.frame(for: .centered, in: screen, preferredSize: CGSize(width: 800, height: 500))

    #expect(frame.size == CGSize(width: 800, height: 500))
    #expect(abs(frame.midX - screen.midX) < 0.1)
    #expect(abs(frame.midY - screen.midY) < 0.1)
}
