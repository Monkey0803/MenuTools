import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MenuTools

// MARK: - 吸附时的触觉反馈

@Test("只在进入新的吸附区域时触发触觉反馈")
func hapticFeedbackTriggersOnlyWhenSnapZoneChanges() {
    let left = WindowSnapPreviewPlan(layout: .leftHalf, screenIndex: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    let leftAgain = WindowSnapPreviewPlan(layout: .leftHalf, screenIndex: 0, frame: CGRect(x: 0, y: 0, width: 120, height: 100))
    let right = WindowSnapPreviewPlan(layout: .rightHalf, screenIndex: 0, frame: CGRect(x: 200, y: 0, width: 100, height: 100))
    let otherScreen = WindowSnapPreviewPlan(layout: .leftHalf, screenIndex: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))

    #expect(WindowSnapFeedback.shouldTriggerHaptic(previous: nil, next: left))
    #expect(!WindowSnapFeedback.shouldTriggerHaptic(previous: left, next: leftAgain))
    #expect(WindowSnapFeedback.shouldTriggerHaptic(previous: left, next: right))
    #expect(WindowSnapFeedback.shouldTriggerHaptic(previous: left, next: otherScreen))
    #expect(!WindowSnapFeedback.shouldTriggerHaptic(previous: left, next: nil))
    #expect(!WindowSnapFeedback.shouldTriggerHaptic(previous: nil, next: nil))
}

// MARK: - 拖出已吸附窗口恢复原尺寸

@Test("只有关闭缩小放大按钮所在横排会触发拖出恢复")
func unsnapRestoreOnlyStartsInWindowControlRow() {
    let frame = CGRect(x: 100, y: 100, width: 700, height: 500)

    #expect(WindowDragRestoreZone.contains(CGPoint(x: 140, y: 580), in: frame))
    #expect(!WindowDragRestoreZone.contains(CGPoint(x: 140, y: 596), in: frame))
    #expect(!WindowDragRestoreZone.contains(CGPoint(x: 140, y: 562), in: frame))
    #expect(!WindowDragRestoreZone.contains(CGPoint(x: 140, y: 580), in: CGRect(x: 100, y: 100, width: 0, height: 0)))
}

@Test("拖出已吸附窗口时恢复吸附前的尺寸，并保持光标仍在窗口内")
func unsnapRestoresPreviousSizeKeepingCursorInside() throws {
    let visible = CGRect(x: 0, y: 0, width: 2560, height: 1410)
    let snapped = CGRect(x: 8, y: 8, width: 1272, height: 1394)      // 左半屏
    let previous = CGRect(x: 800, y: 500, width: 700, height: 500)   // 吸附前
    let cursor = CGPoint(x: 1000, y: 1380)                            // 抓在标题栏上

    let restored = try #require(WindowUnsnapCalculator.restoredFrame(
        current: snapped,
        previous: previous,
        cursor: cursor,
        visibleFrame: visible
    ))

    #expect(restored.size == previous.size)
    #expect(restored.maxY == snapped.maxY)      // 顶边保持，标题栏不会从光标下跑掉
    #expect(restored.contains(cursor))
    #expect(visible.contains(restored))
}

@Test("尺寸没有实际变化时不做恢复")
func unsnapSkipsWhenSizeUnchanged() {
    let visible = CGRect(x: 0, y: 0, width: 2560, height: 1410)
    let frame = CGRect(x: 100, y: 100, width: 700, height: 500)

    #expect(WindowUnsnapCalculator.restoredFrame(
        current: frame,
        previous: frame,
        cursor: CGPoint(x: 400, y: 550),
        visibleFrame: visible
    ) == nil)

    // 只差 1pt 也算没变化
    #expect(WindowUnsnapCalculator.restoredFrame(
        current: frame,
        previous: CGRect(x: 0, y: 0, width: 701, height: 501),
        cursor: CGPoint(x: 400, y: 550),
        visibleFrame: visible
    ) == nil)
}

@Test("恢复后的窗口仍被夹在显示器可用区域内")
func unsnapClampsIntoVisibleFrame() throws {
    let visible = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let snapped = CGRect(x: 0, y: 0, width: 600, height: 800)
    let previous = CGRect(x: 0, y: 0, width: 1100, height: 700)

    let restored = try #require(WindowUnsnapCalculator.restoredFrame(
        current: snapped,
        previous: previous,
        cursor: CGPoint(x: 300, y: 790),
        visibleFrame: visible
    ))

    #expect(visible.contains(restored))
    #expect(restored.width <= visible.width)
    #expect(restored.contains(CGPoint(x: 300, y: 790)))
}

@Test("吸附前尺寸比屏幕还大时压到可用区域尺寸")
func unsnapShrinksOversizedPreviousFrame() throws {
    let visible = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let snapped = CGRect(x: 0, y: 0, width: 600, height: 800)

    let restored = try #require(WindowUnsnapCalculator.restoredFrame(
        current: snapped,
        previous: CGRect(x: 0, y: 0, width: 2000, height: 1600),
        cursor: CGPoint(x: 300, y: 790),
        visibleFrame: visible
    ))

    #expect(restored.size == visible.size)
}

// MARK: - 配置向后兼容

@Test("旧配置缺少触觉反馈与拖出恢复开关时回落到默认开启")
func windowManagerConfigurationDecodesDragEnhancementDefaults() throws {
    let legacy = """
    {
      "options": {"screenPadding": 8, "windowGap": 8, "snapDistance": 24, "defaultWindowWidth": 900, "defaultWindowHeight": 650},
      "presets": [],
      "applicationRules": [],
      "excludedBundleIdentifiers": [],
      "automaticApplicationRules": false,
      "edgeSnappingEnabled": true
    }
    """

    let decoded = try JSONDecoder().decode(WindowManagerConfiguration.self, from: Data(legacy.utf8))
    #expect(decoded.hapticFeedbackOnSnap)
    #expect(decoded.restoreSizeWhenDraggingOut)
    #expect(!decoded.detailedSnapAreas)
    #expect(decoded.edgeSnappingEnabled)
}

// MARK: - 落点预览的生长动画

@Test("预览从落点所贴的屏幕边缘长出来")
func previewAnimationGrowsFromSnappedEdge() {
    let screens = [
        WindowSnapScreen(
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)
        )
    ]

    // 左半屏整屏高：从左边中点长出来，而不是从角落
    let leftHalf = WindowSnapPreviewPlan(layout: .leftHalf, screenIndex: 0, frame: CGRect(x: 0, y: 0, width: 600, height: 800))
    #expect(WindowSnapPreviewAnimation.origin(for: leftHalf, screens: screens) == CGPoint(x: 0, y: 400))

    // 上半屏整屏宽：从上边中点
    let topHalf = WindowSnapPreviewPlan(layout: .topHalf, screenIndex: 0, frame: CGRect(x: 0, y: 400, width: 1200, height: 400))
    #expect(WindowSnapPreviewAnimation.origin(for: topHalf, screens: screens) == CGPoint(x: 600, y: 800))

    // 左上四分之一：从左上角
    let topLeft = WindowSnapPreviewPlan(layout: .topLeft, screenIndex: 0, frame: CGRect(x: 0, y: 400, width: 600, height: 400))
    #expect(WindowSnapPreviewAnimation.origin(for: topLeft, screens: screens) == CGPoint(x: 0, y: 800))

    // 不贴任何边（居中类）：用中心
    let centered = WindowSnapPreviewPlan(layout: .centered, screenIndex: 0, frame: CGRect(x: 300, y: 200, width: 600, height: 400))
    #expect(WindowSnapPreviewAnimation.origin(for: centered, screens: screens) == CGPoint(x: 600, y: 400))

    let initial = WindowSnapPreviewAnimation.initialFrame(for: leftHalf, screens: screens)
    #expect(initial.midX == 0)
    #expect(initial.size == WindowSnapPreviewAnimation.initialSize)
    #expect(initial.midY == 400)
}

// MARK: - 精细吸附区域（可开关）

@Test("精细吸附区域把顶边给最大化、底边给三分区")
func detailedSnapAreasExtendEdgeZones() {
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let threshold: CGFloat = 24

    // 默认模型不变
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 600, y: 799), in: screen, threshold: threshold) == .topHalf)
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 600, y: 2), in: screen, threshold: threshold) == .bottomHalf)

    // 精细模型
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 600, y: 799), in: screen, threshold: threshold, detailed: true) == .maximize)
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 100, y: 2), in: screen, threshold: threshold, detailed: true) == .firstThird)
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 600, y: 2), in: screen, threshold: threshold, detailed: true) == .bottomHalf)
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 1100, y: 2), in: screen, threshold: threshold, detailed: true) == .lastThird)

    // 上下半屏改由左右边缘的上/下三分之一区域提供
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 2, y: 400), in: screen, threshold: threshold, detailed: true) == .leftHalf)
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 2, y: 700), in: screen, threshold: threshold, detailed: true) == .topHalf)
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 2, y: 100), in: screen, threshold: threshold, detailed: true) == .bottomHalf)
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 1198, y: 400), in: screen, threshold: threshold, detailed: true) == .rightHalf)

    // 四角两种模型一致
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 2, y: 798), in: screen, threshold: threshold, detailed: true) == .topLeft)
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 1198, y: 2), in: screen, threshold: threshold, detailed: true) == .bottomRight)
}

@Test("精细模型同样作用于窗口贴边判定")
func detailedSnapAreasApplyToPressedWindow() {
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let size = CGSize(width: 400, height: 300)
    let threshold: CGFloat = 24

    #expect(WindowSnapResolver.layout(
        pressedWindowFrame: CGRect(origin: CGPoint(x: 400, y: 500), size: size),
        in: screen,
        threshold: threshold
    ) == .topHalf)
    #expect(WindowSnapResolver.layout(
        pressedWindowFrame: CGRect(origin: CGPoint(x: 400, y: 500), size: size),
        in: screen,
        threshold: threshold,
        detailed: true
    ) == .maximize)
    #expect(WindowSnapResolver.layout(
        pressedWindowFrame: CGRect(origin: CGPoint(x: 100, y: 0), size: size),
        in: screen,
        threshold: threshold,
        detailed: true
    ) == .firstThird)
}

@Test("预览规划器会把精细开关透传给吸附判定")
func previewPlannerPassesDetailedFlag() throws {
    let screens = [
        WindowSnapScreen(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800))
    ]
    let options = WindowManagerOptions(screenPadding: 0, windowGap: 0, snapDistance: 24)
    let point = CGPoint(x: 600, y: 799)

    #expect(WindowSnapPreviewPlanner.plan(for: point, screens: screens, options: options)?.layout == .topHalf)
    #expect(WindowSnapPreviewPlanner.plan(for: point, screens: screens, options: options, detailedSnapAreas: true)?.layout == .maximize)
}

// MARK: - menutools:// 链接

@Test("布局名与 URL 名称可以互相转换")
func windowLayoutURLNameRoundTrips() {
    #expect(WindowLayoutURLName.name(for: .leftHalf) == "left-half")
    #expect(WindowLayoutURLName.name(for: .topLeftSixth) == "top-left-sixth")
    #expect(WindowLayoutURLName.name(for: .toggleFullscreen) == "toggle-fullscreen")
    #expect(WindowLayoutURLName.name(for: .stashLeft) == "stash-left")

    #expect(WindowLayoutURLName.layout(from: "left-half") == .leftHalf)
    #expect(WindowLayoutURLName.layout(from: "TOP-LEFT-SIXTH") == .topLeftSixth)
    #expect(WindowLayoutURLName.layout(from: " stash-left ") == .stashLeft)
    #expect(WindowLayoutURLName.layout(from: "nonsense") == nil)
    #expect(WindowLayoutURLName.layout(from: "") == nil)

    // 全部布局都能往返
    for layout in WindowLayout.allCases {
        #expect(
            WindowLayoutURLName.layout(from: WindowLayoutURLName.name(for: layout)) == layout,
            "\(layout.rawValue) 的 URL 名称无法往返"
        )
    }
}

@Test("解析 menutools:// 链接得到布局或预设")
func urlSchemeParsesWindowActions() throws {
    func action(_ string: String) -> MenuToolsURLAction? {
        MenuToolsURL.action(for: URL(string: string)!)
    }

    #expect(action("menutools://window?layout=left-half") == .layout(.leftHalf))
    // 与 Rectangle 的 execute-action 习惯一致
    #expect(action("menutools://action?name=maximize") == .layout(.maximize))
    #expect(action("menutools://preset?name=%E5%BC%80%E5%8F%91") == .preset("开发"))

    #expect(action("menutools://window?layout=nonsense") == nil)
    #expect(action("menutools://window") == nil)
    #expect(action("menutools://preset?name=") == nil)
    #expect(action("menutools://unknown?layout=left-half") == nil)
    #expect(action("https://example.com/window?layout=left-half") == nil)
}

// MARK: - 自定义吸附区域

@Test("吸附区域判定与内置默认动作保持一致")
func snapAreaResolutionKeepsBuiltInDefaults() {
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let threshold: CGFloat = 24
    let mapping = WindowSnapAreaMapping()

    #expect(WindowSnapResolver.area(for: CGPoint(x: 2, y: 400), in: screen, threshold: threshold) == .left)
    #expect(WindowSnapResolver.area(for: CGPoint(x: 1198, y: 400), in: screen, threshold: threshold) == .right)
    #expect(WindowSnapResolver.area(for: CGPoint(x: 600, y: 799), in: screen, threshold: threshold) == .top)
    #expect(WindowSnapResolver.area(for: CGPoint(x: 600, y: 2), in: screen, threshold: threshold) == .bottom)
    #expect(WindowSnapResolver.area(for: CGPoint(x: 2, y: 798), in: screen, threshold: threshold) == .topLeft)
    #expect(WindowSnapResolver.area(for: CGPoint(x: 1198, y: 2), in: screen, threshold: threshold) == .bottomRight)
    #expect(WindowSnapResolver.area(for: CGPoint(x: 600, y: 400), in: screen, threshold: threshold) == nil)

    // 默认映射 == 原行为
    #expect(mapping.action(for: .left, detailed: false) == .leftHalf)
    #expect(mapping.action(for: .top, detailed: false) == .topHalf)
    #expect(mapping.action(for: .top, detailed: true) == .maximize)
    #expect(mapping.action(for: .topLeft, detailed: false) == .topLeft)
    #expect(mapping.action(for: .bottomCenterThird, detailed: true) == .bottomHalf)
    #expect(mapping.action(for: .bottomLeftThird, detailed: true) == .firstThird)
    #expect(mapping.action(for: .leftUpperThird, detailed: true) == .topHalf)
    #expect(mapping.isEmpty)
}

@Test("用户可以把任意吸附区域改成任意布局")
func snapAreaOverridesReplaceBuiltInActions() {
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let threshold: CGFloat = 24
    var mapping = WindowSnapAreaMapping()
    mapping.setOverride(.firstThird, for: .left)
    mapping.setOverride(.maximize, for: .topLeft)
    mapping.setOverride(.topHalf, for: .top)   // 覆盖精细模型的内置最大化

    #expect(WindowSnapResolver.layout(for: CGPoint(x: 2, y: 400), in: screen, threshold: threshold, mapping: mapping) == .firstThird)
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 2, y: 798), in: screen, threshold: threshold, mapping: mapping) == .maximize)
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 600, y: 799), in: screen, threshold: threshold, detailed: true, mapping: mapping) == .topHalf)

    // 没有覆盖的区域仍是内置动作
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 600, y: 2), in: screen, threshold: threshold, mapping: mapping) == .bottomHalf)

    // 清掉覆盖后回到内置动作
    mapping.setOverride(nil, for: .left)
    #expect(mapping.override(for: .left) == nil)
    #expect(WindowSnapResolver.layout(for: CGPoint(x: 2, y: 400), in: screen, threshold: threshold, mapping: mapping) == .leftHalf)

    mapping.removeAll()
    #expect(mapping.isEmpty)
}

@Test("窗口贴边判定同样遵循自定义映射")
func pressedWindowSnapHonorsOverrides() {
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    var mapping = WindowSnapAreaMapping()
    mapping.setOverride(.rightHalf, for: .top)

    let frame = CGRect(x: 400, y: 500, width: 400, height: 300)   // 顶部贴边
    #expect(WindowSnapResolver.layout(pressedWindowFrame: frame, in: screen, threshold: 24, mapping: mapping) == .rightHalf)
    #expect(WindowSnapResolver.layout(pressedWindowFrame: frame, in: screen, threshold: 24) == .topHalf)
}

@Test("吸附区域映射只保存覆盖项，且宽容解码")
func snapAreaMappingCodableIsLenient() throws {
    var mapping = WindowSnapAreaMapping()
    mapping.setOverride(.firstThird, for: .left)
    let data = try JSONEncoder().encode(mapping)
    #expect(try JSONDecoder().decode(WindowSnapAreaMapping.self, from: data) == mapping)

    // 未知区域/未知布局被忽略
    let garbage = Data(#"{"left":"firstThird","notAnArea":"leftHalf","top":"notALayout"}"#.utf8)
    let decoded = try JSONDecoder().decode(WindowSnapAreaMapping.self, from: garbage)
    #expect(decoded.override(for: .left) == .firstThird)
    #expect(decoded.override(for: .top) == nil)
    #expect(decoded.overrides.count == 1)

    // 完全不是字典时回落到空映射
    let broken = Data("[1,2,3]".utf8)
    #expect(try JSONDecoder().decode(WindowSnapAreaMapping.self, from: broken).isEmpty)
}

@Test("预览规划器会把自定义映射透传给吸附判定")
func previewPlannerPassesSnapAreaMapping() throws {
    let screens = [
        WindowSnapScreen(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800))
    ]
    let options = WindowManagerOptions(screenPadding: 0, windowGap: 0, snapDistance: 24)
    var mapping = WindowSnapAreaMapping()
    mapping.setOverride(.lastTwoThirds, for: .right)

    let plan = try #require(WindowSnapPreviewPlanner.plan(
        for: CGPoint(x: 1198, y: 400),
        screens: screens,
        options: options,
        snapAreaMapping: mapping
    ))
    #expect(plan.layout == .lastTwoThirds)
}

@Test("旧配置缺少吸附区域映射时回落到全部内置动作")
func windowManagerConfigurationDecodesSnapAreaDefault() throws {
    let legacy = """
    {
      "options": {"screenPadding": 8, "windowGap": 8, "snapDistance": 24, "defaultWindowWidth": 900, "defaultWindowHeight": 650},
      "presets": [],
      "applicationRules": [],
      "excludedBundleIdentifiers": [],
      "automaticApplicationRules": false,
      "edgeSnappingEnabled": true
    }
    """
    let decoded = try JSONDecoder().decode(WindowManagerConfiguration.self, from: Data(legacy.utf8))
    #expect(decoded.snapAreaMapping.isEmpty)
    #expect(decoded.snapAreaMapping.action(for: .left, detailed: false) == .leftHalf)
}
