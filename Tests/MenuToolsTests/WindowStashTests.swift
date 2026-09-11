import AppKit
import CoreGraphics
import Testing
@testable import MenuTools

// MARK: - 收纳到屏幕边缘（对标 Loop 的 stash）

@Test("收纳到屏幕左缘只留一条可见边")
func stashLeftLeavesVisibleStrip() {
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let size = CGSize(width: 600, height: 400)

    let frame = WindowLayoutCalculator.frame(
        for: .stashLeft,
        in: screen,
        preferredSize: size,
        options: WindowManagerOptions(screenPadding: 0, windowGap: 0)
    )

    #expect(frame.maxX == WindowLayoutCalculator.stashVisibleStrip)
    #expect(frame.width == 600)
    #expect(frame.height == 400)
    #expect(abs(frame.midY - screen.midY) < 0.1)
}

@Test("收纳到屏幕右缘只留一条可见边")
func stashRightLeavesVisibleStrip() {
    let screen = CGRect(x: 100, y: 50, width: 1000, height: 600)
    let frame = WindowLayoutCalculator.frame(
        for: .stashRight,
        in: screen,
        preferredSize: CGSize(width: 400, height: 300),
        options: WindowManagerOptions(screenPadding: 0, windowGap: 0)
    )

    #expect(frame.minX == screen.maxX - WindowLayoutCalculator.stashVisibleStrip)
    #expect(frame.width == 400)
}

@Test("收纳遵循屏幕边距设置")
func stashHonorsScreenPadding() {
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let options = WindowManagerOptions(screenPadding: 20, windowGap: 8)

    let left = WindowLayoutCalculator.frame(
        for: .stashLeft,
        in: screen,
        preferredSize: CGSize(width: 600, height: 400),
        options: options
    )
    #expect(left.maxX == 20 + WindowLayoutCalculator.stashVisibleStrip)

    let right = WindowLayoutCalculator.frame(
        for: .stashRight,
        in: screen,
        preferredSize: CGSize(width: 600, height: 400),
        options: options
    )
    #expect(right.minX == 1180 - WindowLayoutCalculator.stashVisibleStrip)
}

@Test("收纳保持窗口尺寸并把纵向位置夹在可用区域内")
func stashClampsVerticalPositionAndSize() {
    let screen = CGRect(x: 100, y: 50, width: 1000, height: 600)
    let options = WindowManagerOptions(screenPadding: 0, windowGap: 0)

    // 窗口比可用区域还高：高度压到可用区域，并贴住下边缘。
    let tall = WindowLayoutCalculator.frame(
        for: .stashLeft,
        in: screen,
        preferredSize: CGSize(width: 400, height: 900),
        options: options
    )
    #expect(tall.height == 600)
    #expect(tall.minY == 50)

    // 窗口很矮时纵向居中。
    let short = WindowLayoutCalculator.frame(
        for: .stashLeft,
        in: screen,
        preferredSize: CGSize(width: 400, height: 200),
        options: options
    )
    #expect(abs(short.midY - screen.midY) < 0.1)
}

@Test("收纳标记只对左右两个方向为真")
func stashFlagOnlyMatchesStashLayouts() {
    #expect(WindowLayout.stashLeft.isStash)
    #expect(WindowLayout.stashRight.isStash)

    for layout in [WindowLayout.leftHalf, .rightHalf, .moveLeft, .restore, .centered, .topHalf] {
        #expect(!layout.isStash, "\(layout.rawValue) 不是收纳布局")
    }
}

@Test("收纳布局不参与同族循环")
func stashLayoutsAreNotPartOfCycles() {
    #expect(WindowLayoutCycle.next(after: .stashLeft) == nil)
    #expect(WindowLayoutCycle.next(after: .stashRight) == nil)
}

@Test("收纳与收回的状态判定按同一目标复用重复触发器")
func stashToggleUsesRepeatTrackerPerTarget() {
    var tracker = WindowRepeatTracker()

    let firstStash = tracker.isRepeat(layout: .stashLeft, targetKey: "chrome|窗口 A")
    let secondStash = tracker.isRepeat(layout: .stashLeft, targetKey: "chrome|窗口 A")
    let otherWindow = tracker.isRepeat(layout: .stashLeft, targetKey: "chrome|窗口 B")

    #expect(!firstStash)
    #expect(secondStash)
    #expect(!otherWindow)
}
