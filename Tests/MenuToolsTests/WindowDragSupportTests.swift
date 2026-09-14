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
    #expect(decoded.edgeSnappingEnabled)
}
