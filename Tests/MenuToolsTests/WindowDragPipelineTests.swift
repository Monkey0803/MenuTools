import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MenuTools

// MARK: - 假的拖拽环境

@MainActor
private final class FakeTarget: NSObject {
    let bundleIdentifier: String
    var frame: CGRect
    var appliedFrames: [CGRect] = []

    init(bundleIdentifier: String, frame: CGRect) {
        self.bundleIdentifier = bundleIdentifier
        self.frame = frame
    }
}

@MainActor
private final class FakePointer {
    var location: CGPoint = .zero
    var uptime: TimeInterval = 0
}

@MainActor
private final class FakePreview {
    var isVisible = false
    var plans: [WindowSnapPreviewPlan] = []
    var initialFrames: [CGRect?] = []
    var hideCount = 0
}

@MainActor
private final class FakeCounter {
    var value = 0
}

@MainActor
private struct DragHarness {
    let service: WindowManagementService
    let target: FakeTarget
    let pointer: FakePointer
    let preview: FakePreview
    let haptics: FakeCounter
    let defaults: UserDefaults

    static func make(
        windowFrame: CGRect,
        bundleIdentifier: String = "com.example.Editor",
        previousFrame: CGRect? = nil,
        appliedFrame: CGRect? = nil,
        configure: (inout WindowManagerConfiguration) -> Void = { _ in }
    ) throws -> DragHarness {
        let suiteName = "MenuTools-WindowDragPipelineTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        var configuration = WindowManagerConfiguration(edgeSnappingEnabled: true)
        configure(&configuration)
        defaults.set(try JSONEncoder().encode(configuration), forKey: "windowManagement.configuration")

        let memory = WindowFrameMemory(defaults: defaults)
        if let previousFrame { memory.rememberPreviousFrame(previousFrame, for: bundleIdentifier) }

        let target = FakeTarget(bundleIdentifier: bundleIdentifier, frame: windowFrame)
        let pointer = FakePointer()
        let preview = FakePreview()
        let haptics = FakeCounter()

        let environment = WindowDragEnvironment(
            pointerLocation: { pointer.location },
            uptime: { pointer.uptime },
            isOptionPressed: { false },
            showPreview: { plan, initialFrame in
                preview.plans.append(plan)
                preview.initialFrames.append(initialFrame)
                preview.isVisible = true
            },
            hidePreview: {
                preview.isVisible = false
                preview.hideCount += 1
            },
            isPreviewVisible: { preview.isVisible },
            performHapticFeedback: { haptics.value += 1 },
            captureTarget: { _ in
                WindowDragEnvironment.Target(handle: target, bundleIdentifier: target.bundleIdentifier)
            },
            targetFrame: { handle in (handle.handle as? FakeTarget)?.frame },
            setTargetFrame: { frame, handle in
                guard let fake = handle.handle as? FakeTarget else { return false }
                fake.appliedFrames.append(frame)
                fake.frame = frame
                return true
            }
        )

        let service = WindowManagementService(defaults: defaults, dragEnvironment: environment)
        if let appliedFrame { service.recordAppliedFrame(appliedFrame, bundleIdentifier: bundleIdentifier) }
        return DragHarness(
            service: service,
            target: target,
            pointer: pointer,
            preview: preview,
            haptics: haptics,
            defaults: defaults
        )
    }

    /// 模拟一次完整拖拽：按下 → 若干拖动 → 松手
    func drag(from start: CGPoint, through points: [CGPoint], releaseAt end: CGPoint) {
        pointer.location = start
        pointer.uptime += 1
        service.handleMouseEvent(.leftMouseDown)
        for point in points {
            pointer.location = point
            pointer.uptime += 0.2
            service.handleMouseEvent(.leftMouseDragged)
        }
        pointer.location = end
        pointer.uptime += 0.2
        service.handleMouseEvent(.leftMouseUp)
    }

}

// MARK: - 场景

@MainActor
@Test("拖拽中 AX 不上报新位置时预览仍然出现")
func previewShowsEvenWhenWindowFrameLags() throws {
    // 模拟真实情况：应用直到松手才更新 AX 位置，拖动过程中窗口帧一直是按下时的值
    let window = CGRect(x: 400, y: 300, width: 700, height: 500)
    let harness = try DragHarness.make(windowFrame: window)
    let screen = try #require(NSScreen.screens.first)
    let start = CGPoint(x: window.midX, y: window.maxY - 10)   // 标题栏
    let edge = CGPoint(x: screen.visibleFrame.minX + 4, y: start.y)

    // 先只按下并拖动，确认「窗口帧没更新」的前提下预览照样出现
    harness.pointer.location = start
    harness.pointer.uptime += 1
    harness.service.handleMouseEvent(.leftMouseDown)
    for point in [CGPoint(x: start.x - 40, y: start.y), edge] {
        harness.pointer.location = point
        harness.pointer.uptime += 0.2
        harness.service.handleMouseEvent(.leftMouseDragged)
    }

    #expect(!harness.preview.plans.isEmpty, "窗口帧滞后时预览仍应出现")
    #expect(harness.preview.plans.first?.layout == .leftHalf)
    #expect(harness.target.frame == window, "拖拽过程中 AX 一直报旧位置（复现滞后）")

    harness.pointer.location = edge
    harness.pointer.uptime += 0.2
    harness.service.handleMouseEvent(.leftMouseUp)
}

@MainActor
@Test("窗口已贴边而光标离得远时，松手仍然吸附")
func releaseSnapsWhenWindowPressedAgainstEdgeEvenIfCursorIsFar() throws {
    let screen = try #require(NSScreen.screens.first)
    let visible = screen.visibleFrame
    // 窗口左缘已经贴住屏幕左缘，但光标停在离左缘 300pt 的位置
    let pressed = CGRect(x: visible.minX, y: visible.minY + 100, width: 900, height: 500)
    let harness = try DragHarness.make(windowFrame: pressed)
    let start = CGPoint(x: pressed.midX, y: pressed.maxY - 10)
    let end = CGPoint(x: visible.minX + 300, y: start.y)

    harness.drag(from: start, through: [end], releaseAt: end)

    #expect(harness.target.appliedFrames.count == 1, "窗口贴边时应吸附一次")
    let applied = try #require(harness.target.appliedFrames.first)
    // 默认边距 8pt、间距 8pt：左半屏宽度 = (可用宽度 − 24) / 2
    #expect(abs(applied.width - (visible.width - 24) / 2) < 40, "应被布局成左半屏宽度，实际 \(applied.width)")
    #expect(abs(applied.minX - (visible.minX + 8)) < 8, "落点应贴在屏幕左缘附近，实际 \(applied.minX)")
}

@MainActor
@Test("触觉反馈只在进入新的落点区域时触发")
func hapticsFireOnlyWhenZoneChanges() throws {
    let window = CGRect(x: 400, y: 600, width: 600, height: 400)
    let harness = try DragHarness.make(windowFrame: window)
    let screen = try #require(NSScreen.screens.first)
    let visible = screen.visibleFrame
    let start = CGPoint(x: window.midX, y: window.maxY - 10)

    harness.pointer.location = start
    harness.service.handleMouseEvent(.leftMouseDown)
    // 左边缘 → 顶边缘 → 顶边缘（同一区域，不应再响）
    // 注意：吸附带按屏幕完整范围判定（含菜单栏那一条），所以用 screen.frame.maxY 而不是 visibleFrame
    for point in [
        CGPoint(x: visible.minX + 4, y: visible.midY),
        CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 4),
        CGPoint(x: screen.frame.midX + 20, y: screen.frame.maxY - 6)
    ] {
        harness.pointer.location = point
        harness.pointer.uptime += 0.2
        harness.service.handleMouseEvent(.leftMouseDragged)
    }
    harness.pointer.location = .zero
    harness.service.handleMouseEvent(.leftMouseUp)

    #expect(harness.haptics.value == 2, "进入两个不同区域应各响一次，同区域内不重复；实际 \(harness.haptics.value)")
}

@MainActor
@Test("在窗口正文里划选内容不会预览也不会吸附")
func draggingInContentAreaIsIgnored() throws {
    let window = CGRect(x: 400, y: 300, width: 700, height: 500)
    let harness = try DragHarness.make(windowFrame: window)
    let screen = try #require(NSScreen.screens.first)
    // 按下点落在窗口正文中间，不是标题栏
    let start = CGPoint(x: window.midX, y: window.midY)
    let end = CGPoint(x: screen.visibleFrame.minX + 4, y: start.y)

    harness.drag(from: start, through: [end], releaseAt: end)

    #expect(harness.preview.plans.isEmpty)
    #expect(harness.target.appliedFrames.isEmpty)
    #expect(harness.haptics.value == 0)
}

@MainActor
@Test("从标题栏控制行拖出已吸附窗口时恢复原尺寸且只触发一次")
func draggingOutOfControlRowRestoresSizeOnce() throws {
    let screen = try #require(NSScreen.screens.first)
    let visible = screen.visibleFrame
    let snapped = CGRect(x: visible.minX + 8, y: visible.minY + 8, width: (visible.width - 24) / 2, height: visible.height - 16)
    let previous = CGRect(x: 900, y: 400, width: 700, height: 520)
    let harness = try DragHarness.make(
        windowFrame: snapped,
        previousFrame: previous,
        appliedFrame: snapped,
        configure: { $0.restoreSizeWhenDraggingOut = true }
    )

    // 控制行：窗口顶部往下 12–32pt 的那一条
    let start = CGPoint(x: snapped.midX, y: snapped.maxY - 20)
    let end = CGPoint(x: snapped.midX + 260, y: start.y)
    harness.drag(from: start, through: [CGPoint(x: start.x + 60, y: start.y), end], releaseAt: end)

    #expect(harness.target.appliedFrames.count >= 1)
    #expect(harness.target.appliedFrames.first?.size == previous.size, "第一次写回应是恢复后的尺寸")
    let restores = harness.target.appliedFrames.filter { $0.size == previous.size }
    #expect(restores.count == 1, "恢复尺寸只应触发一次")
}

@MainActor
@Test("关闭「拖出恢复尺寸」后不改变窗口大小")
func unsnapRespectsDisabledSetting() throws {
    let screen = try #require(NSScreen.screens.first)
    let visible = screen.visibleFrame
    let snapped = CGRect(x: visible.minX + 8, y: visible.minY + 8, width: (visible.width - 24) / 2, height: visible.height - 16)
    let previous = CGRect(x: 900, y: 400, width: 700, height: 520)
    let harness = try DragHarness.make(
        windowFrame: snapped,
        previousFrame: previous,
        appliedFrame: snapped,
        configure: { $0.restoreSizeWhenDraggingOut = false }
    )

    let start = CGPoint(x: snapped.midX, y: snapped.maxY - 20)
    let end = CGPoint(x: snapped.midX + 260, y: start.y)
    harness.drag(from: start, through: [end], releaseAt: end)

    let sizeChanges = harness.target.appliedFrames.filter { $0.size == previous.size }
    #expect(sizeChanges.isEmpty)
}
