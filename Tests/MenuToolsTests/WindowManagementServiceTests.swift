import AppKit
import CoreGraphics
import Testing
@testable import MenuTools

@Test("窗口布局支持左右分屏和四象限")
func windowLayoutCalculatesFrames() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    let left = WindowLayoutCalculator.frame(for: .leftHalf, in: screen)
    let maxWidth = WindowLayoutCalculator.frame(for: .maxWidth, in: screen, preferredSize: CGSize(width: 800, height: 500))
    let topLeft = WindowLayoutCalculator.frame(for: .topLeft, in: screen)
    let topRight = WindowLayoutCalculator.frame(for: .topRight, in: screen)
    let bottomLeft = WindowLayoutCalculator.frame(for: .bottomLeft, in: screen)
    let bottomRight = WindowLayoutCalculator.frame(for: .bottomRight, in: screen)

    #expect(left.width < screen.width)
    #expect(left.height < screen.height)
    #expect(maxWidth.width == screen.width - 16)
    #expect(maxWidth.height == 500)
    #expect(abs(maxWidth.midY - screen.midY) < 0.1)
    #expect(topLeft.minX < screen.midX)
    #expect(topRight.minX > screen.midX)
    #expect(bottomLeft.minX < screen.midX)
    #expect(bottomRight.minX > screen.midX)
    #expect(topLeft.minY > bottomLeft.minY)
    #expect(topRight.minY > screen.midY)
    #expect(bottomRight.minY < screen.midY)
}

@Test("窗口坐标转换不会翻转四分之一的上下位置")
func windowCoordinateConversionPreservesQuadrants() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let topRight = WindowLayoutCalculator.frame(for: .topRight, in: screen)
    let bottomRight = WindowLayoutCalculator.frame(for: .bottomRight, in: screen)

    let topRightAX = WindowCoordinateConverter.toAccessibility(topRight, desktopTop: screen.maxY)
    let bottomRightAX = WindowCoordinateConverter.toAccessibility(bottomRight, desktopTop: screen.maxY)

    #expect(topRightAX.minY < bottomRightAX.minY)
    #expect(WindowCoordinateConverter.fromAccessibility(topRightAX, desktopTop: screen.maxY) == topRight)
    #expect(WindowCoordinateConverter.fromAccessibility(bottomRightAX, desktopTop: screen.maxY) == bottomRight)
}

@Test("设置窗口激活后优先使用最近的外部窗口")
func windowTargetResolverKeepsExternalTarget() {
    #expect(WindowTargetResolver.preferredProcessIdentifier(frontmost: 100, remembered: 200, own: 100) == 200)
    #expect(WindowTargetResolver.preferredProcessIdentifier(frontmost: 300, remembered: 200, own: 100) == 300)
    #expect(WindowTargetResolver.preferredProcessIdentifier(frontmost: 100, remembered: nil, own: 100) == nil)
}

@Test("窗口布局居中保留目标尺寸")
func windowLayoutCentersRequestedSize() {
    let screen = CGRect(x: 100, y: 80, width: 1200, height: 800)
    let frame = WindowLayoutCalculator.frame(for: .centered, in: screen, preferredSize: CGSize(width: 800, height: 500))

    #expect(frame.size == CGSize(width: 800, height: 500))
    #expect(abs(frame.midX - screen.midX) < 0.1)
    #expect(abs(frame.midY - screen.midY) < 0.1)
}

@Test("窗口管理目录覆盖截图中的全部固定布局")
func windowLayoutCatalogContainsAllFixedLayouts() {
    #expect(WindowLayout.allCases.count == 58)
    #expect(WindowLayout.allCases.contains(.toggleFullscreen))
    #expect(WindowLayout.allCases.contains(.almostMaximize))
    #expect(WindowLayout.allCases.contains(.maxHeight))
    #expect(WindowLayout.allCases.contains(.topLeftSixth))
    #expect(WindowLayout.allCases.contains(.bottomCenterSixth))
    #expect(WindowLayout.allCases.contains(.topFirstFourth))
    #expect(WindowLayout.allCases.contains(.topLastFourth))
    #expect(WindowLayout.allCases.contains(.firstThreeFourths))
    #expect(WindowLayout.allCases.contains(.lastThreeFourths))
    #expect(WindowLayout.allCases.contains(.topCenterTwoThirds))
    #expect(WindowLayout.allCases.contains(.bottomCenterTwoThirds))
    #expect(WindowLayout.allCases.contains(.movePreviousDesktop))
    #expect(WindowLayout.allCases.contains(.moveDown))
}

@Test("三等分、四等分和六等分布局都落在显示器可见区域")
func windowLayoutFractionalFramesStayInsideScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let layouts: [WindowLayout] = [
        .topLeftSixth, .topCenterSixth, .topRightSixth,
        .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
        .firstThird, .centerThird, .lastThird,
        .firstFourth, .secondFourth, .thirdFourth, .lastFourth,
        .topFirstFourth, .topSecondFourth, .topThirdFourth, .topLastFourth,
        .topThird, .middleThird, .bottomThird,
        .topTwoThirds, .bottomTwoThirds,
        .topThreeFourths, .bottomThreeFourths,
        .topCenterTwoThirds, .bottomCenterTwoThirds
    ]

    for layout in layouts {
        let frame = WindowLayoutCalculator.frame(for: layout, in: screen)
        #expect(screen.contains(frame), "\(layout.rawValue) 超出屏幕")
        #expect(frame.width > 0)
        #expect(frame.height > 0)
    }
}

@Test("窗口比例布局保持左右和上下方向")
func windowLayoutFractionalFramesKeepDirections() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let top = WindowLayoutCalculator.frame(for: .topCenterTwoThirds, in: screen)
    let bottom = WindowLayoutCalculator.frame(for: .bottomCenterTwoThirds, in: screen)
    let first = WindowLayoutCalculator.frame(for: .firstThird, in: screen)
    let last = WindowLayoutCalculator.frame(for: .lastThird, in: screen)

    #expect(top.midY > bottom.midY)
    #expect(abs(top.midX - screen.midX) < 0.1)
    #expect(abs(bottom.midX - screen.midX) < 0.1)
    #expect(first.midX < screen.midX)
    #expect(last.midX > screen.midX)
}

@Test("每个窗口布局都有可用的系统图标")
func windowLayoutSymbolsAreAvailable() {
    for layout in WindowLayout.allCases {
        #expect(
            NSImage(systemSymbolName: layout.symbol, accessibilityDescription: nil) != nil,
            "缺少图标：\(layout.rawValue) -> \(layout.symbol)"
        )
    }
}

@Test("最大化相关布局使用不同图标")
func maximizeLayoutsUseDistinctSymbols() {
    let symbols = [
        WindowLayout.maximize.symbol,
        WindowLayout.toggleFullscreen.symbol,
        WindowLayout.almostMaximize.symbol
    ]
    #expect(Set(symbols).count == symbols.count)
}
