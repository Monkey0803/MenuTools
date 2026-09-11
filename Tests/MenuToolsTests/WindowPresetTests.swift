import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MenuTools

// MARK: - 固定尺寸预设

@Test("固定尺寸预设按屏幕可用区域夹取")
func frameClamperKeepsWindowInsideVisibleFrame() {
    let visible = CGRect(x: 0, y: 0, width: 1200, height: 800)

    // 已经完全落在可用区域内：位置和尺寸都不变。
    #expect(WindowFrameClamper.clamp(
        CGRect(x: 100, y: 100, width: 400, height: 300),
        into: visible
    ) == CGRect(x: 100, y: 100, width: 400, height: 300))

    // 超出右侧和顶部：只做最小平移，不改变尺寸。
    #expect(WindowFrameClamper.clamp(
        CGRect(x: 1100, y: 750, width: 400, height: 300),
        into: visible
    ) == CGRect(x: 800, y: 500, width: 400, height: 300))

    // 比可用区域还大：压缩到可用区域。
    #expect(WindowFrameClamper.clamp(
        CGRect(x: -50, y: -50, width: 2000, height: 1600),
        into: visible
    ) == visible)
}

@Test("固定尺寸预设按重叠面积选择显示器")
func frameClamperPicksScreenWithLargestOverlap() {
    let screens = [
        CGRect(x: 0, y: 0, width: 1000, height: 800),
        CGRect(x: 1000, y: 0, width: 1600, height: 1000)
    ]

    // 窗口主体落在第二台显示器上。
    let clamped = WindowFrameClamper.clamp(
        CGRect(x: 900, y: 100, width: 800, height: 600),
        into: screens
    )
    #expect(clamped.minX == 1000)
    #expect(clamped.width == 800)
    #expect(clamped.maxX <= 2600)
}

@Test("显示器变化后落单的预设窗口会被带回最近的显示器")
func frameClamperRecoversOffscreenFrame() {
    let screens = [CGRect(x: 0, y: 0, width: 1200, height: 800)]

    let clamped = WindowFrameClamper.clamp(
        CGRect(x: 3000, y: 2000, width: 600, height: 400),
        into: screens
    )
    #expect(screens[0].contains(clamped))
}

@Test("空屏幕列表不会改变预设帧")
func frameClamperWithoutScreensKeepsFrame() {
    let frame = CGRect(x: 3000, y: 2000, width: 600, height: 400)
    #expect(WindowFrameClamper.clamp(frame, into: []) == frame)
}

@Test("预设工厂会拒绝空名称并保留固定尺寸")
func presetFactoryRequiresNameAndKeepsFrame() {
    #expect(WindowPresetFactory.preset(name: "   ", frame: CGRect(x: 0, y: 0, width: 100, height: 100)) == nil)

    let preset = WindowPresetFactory.preset(
        name: "  开发  ",
        frame: CGRect(x: 10, y: 20, width: 800, height: 600)
    )
    #expect(preset?.name == "开发")
    #expect(preset?.frame == CGRect(x: 10, y: 20, width: 800, height: 600))
    #expect(preset?.hasCustomFrame == true)
}

@Test("固定尺寸预设能编码解码并兼容旧数据")
func presetWithFrameRoundTripsAndDecodesLegacyPayload() throws {
    let preset = WindowLayoutPreset(
        name: "开发",
        layout: .centered,
        frame: CGRect(x: 10, y: 20, width: 800, height: 600)
    )
    let data = try JSONEncoder().encode(preset)
    #expect(try JSONDecoder().decode(WindowLayoutPreset.self, from: data) == preset)

    // 旧版本预设只有布局、没有 frame 字段。
    let legacy = Data("""
    {"id":"\(UUID().uuidString)","name":"旧预设","layout":"leftHalf"}
    """.utf8)
    let decoded = try JSONDecoder().decode(WindowLayoutPreset.self, from: legacy)
    #expect(decoded.frame == nil)
    #expect(decoded.hasCustomFrame == false)
    #expect(decoded.layout == .leftHalf)
}

// MARK: - 连按半屏跨显示器

@Test("只有半屏布局参与跨显示器连按")
func displayTraversalOnlyAppliesToHalves() {
    #expect(WindowDisplayTraversal.displayOffset(for: .leftHalf) == -1)
    #expect(WindowDisplayTraversal.displayOffset(for: .rightHalf) == 1)
    #expect(WindowDisplayTraversal.displayOffset(for: .topHalf) == 1)
    #expect(WindowDisplayTraversal.displayOffset(for: .bottomHalf) == 1)

    for layout in [WindowLayout.firstThird, .lastThird, .topLeft, .centered, .maximize, .moveLeft] {
        #expect(WindowDisplayTraversal.displayOffset(for: layout) == nil, "\(layout.rawValue) 不应跨显示器")
    }
}

@Test("跨显示器连按只在同一目标的同一布局上触发")
func displayTraversalTrackerRequiresRepeatedLayoutOnSameTarget() {
    var tracker = WindowRepeatTracker()

    // 变更调用必须放在 #expect 之外：宏展开的闭包里不能调用 mutating 方法。
    let firstLeftHalf = tracker.isRepeat(layout: .leftHalf, targetKey: "A")
    let secondLeftHalf = tracker.isRepeat(layout: .leftHalf, targetKey: "A")
    let thirdLeftHalf = tracker.isRepeat(layout: .leftHalf, targetKey: "A")
    let otherTarget = tracker.isRepeat(layout: .leftHalf, targetKey: "B")
    let otherLayout = tracker.isRepeat(layout: .rightHalf, targetKey: "B")
    let repeatedRightHalf = tracker.isRepeat(layout: .rightHalf, targetKey: "B")

    #expect(!firstLeftHalf)
    #expect(secondLeftHalf)
    #expect(thirdLeftHalf)
    // 换目标或换布局都会重新开始。
    #expect(!otherTarget)
    #expect(!otherLayout)
    #expect(repeatedRightHalf)
}

@Test("显示器索引按方向环绕")
func displayTraversalWrapsAroundScreenList() {
    #expect(WindowDisplayTraversal.nextScreenIndex(current: 0, offset: 1, screenCount: 2) == 1)
    #expect(WindowDisplayTraversal.nextScreenIndex(current: 1, offset: 1, screenCount: 2) == 0)
    #expect(WindowDisplayTraversal.nextScreenIndex(current: 0, offset: -1, screenCount: 2) == 1)
    #expect(WindowDisplayTraversal.nextScreenIndex(current: 0, offset: 1, screenCount: 1) == 0)
    #expect(WindowDisplayTraversal.nextScreenIndex(current: 0, offset: 1, screenCount: 0) == nil)
}

// MARK: - 配置向后兼容（跨显示器开关）

@Test("旧配置缺少跨显示器开关时回落到默认关闭")
func windowManagerConfigurationDecodesTraversalDefault() throws {
    let legacy = """
    {
      "options": {"screenPadding": 8, "windowGap": 8, "snapDistance": 24, "defaultWindowWidth": 900, "defaultWindowHeight": 650},
      "presets": [],
      "applicationRules": [],
      "excludedBundleIdentifiers": [],
      "automaticApplicationRules": false,
      "edgeSnappingEnabled": false
    }
    """

    let decoded = try JSONDecoder().decode(WindowManagerConfiguration.self, from: Data(legacy.utf8))
    #expect(decoded.traverseDisplaysOnRepeat == false)
}
