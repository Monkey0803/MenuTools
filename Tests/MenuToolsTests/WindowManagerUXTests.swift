import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MenuTools

// MARK: - 布局循环（对标 Rectangle 的同族循环）

@Test("三分族布局连按会在同族内循环")
func layoutCycleRotatesHorizontalThirds() {
    #expect(WindowLayoutCycle.next(after: .firstThird) == .centerThird)
    #expect(WindowLayoutCycle.next(after: .centerThird) == .lastThird)
    #expect(WindowLayoutCycle.next(after: .lastThird) == .firstThird)
}

@Test("垂直三分、四分、六分与三分之二族都会循环")
func layoutCycleRotatesRemainingFractionFamilies() {
    #expect(WindowLayoutCycle.next(after: .topThird) == .middleThird)
    #expect(WindowLayoutCycle.next(after: .middleThird) == .bottomThird)
    #expect(WindowLayoutCycle.next(after: .bottomThird) == .topThird)

    #expect(WindowLayoutCycle.next(after: .firstFourth) == .secondFourth)
    #expect(WindowLayoutCycle.next(after: .secondFourth) == .thirdFourth)
    #expect(WindowLayoutCycle.next(after: .thirdFourth) == .lastFourth)
    #expect(WindowLayoutCycle.next(after: .lastFourth) == .firstFourth)

    #expect(WindowLayoutCycle.next(after: .topFirstFourth) == .topSecondFourth)
    #expect(WindowLayoutCycle.next(after: .topThirdFourth) == .topLastFourth)
    #expect(WindowLayoutCycle.next(after: .topLastFourth) == .topFirstFourth)

    #expect(WindowLayoutCycle.next(after: .topLeftSixth) == .topCenterSixth)
    #expect(WindowLayoutCycle.next(after: .topRightSixth) == .bottomLeftSixth)
    #expect(WindowLayoutCycle.next(after: .bottomRightSixth) == .topLeftSixth)

    #expect(WindowLayoutCycle.next(after: .firstTwoThirds) == .lastTwoThirds)
    #expect(WindowLayoutCycle.next(after: .lastTwoThirds) == .firstTwoThirds)

    #expect(WindowLayoutCycle.next(after: .firstThreeFourths) == .lastThreeFourths)
    #expect(WindowLayoutCycle.next(after: .lastThreeFourths) == .firstThreeFourths)
}

@Test("半屏、角落、居中与移动类布局不参与循环")
func layoutCycleSkipsNonFractionalLayouts() {
    let excluded: [WindowLayout] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .maximize, .almostMaximize, .toggleFullscreen,
        .centered, .centerTwoThirds, .centerThreeFourths,
        .topCenterTwoThirds, .bottomCenterTwoThirds,
        .moveLeft, .moveRight, .moveUp, .moveDown,
        .restore, .makeLarger, .makeSmaller
    ]
    for layout in excluded {
        #expect(WindowLayoutCycle.next(after: layout) == nil, "\(layout.rawValue) 不应参与循环")
    }
}

@Test("循环状态在同一目标内连续推进，切换目标后重新开始")
func layoutCycleStateTracksTargetWindow() {
    var state = WindowLayoutCycleState()

    #expect(state.nextLayout(requested: .firstThird, targetKey: "A") == .firstThird)
    #expect(state.nextLayout(requested: .firstThird, targetKey: "A") == .centerThird)
    #expect(state.nextLayout(requested: .firstThird, targetKey: "A") == .lastThird)
    #expect(state.nextLayout(requested: .firstThird, targetKey: "A") == .firstThird)

    // 切换到另一个窗口/应用后，循环重新从第一个布局开始。
    #expect(state.nextLayout(requested: .firstThird, targetKey: "B") == .firstThird)

    // 中途按下不参与循环的布局不会污染循环链。
    #expect(state.nextLayout(requested: .leftHalf, targetKey: "B") == .leftHalf)
    #expect(state.nextLayout(requested: .leftHalf, targetKey: "B") == .leftHalf)
    #expect(state.nextLayout(requested: .firstThird, targetKey: "B") == .firstThird)
}

// MARK: - 吸附目标显示器（按鼠标位置判定）

@Test("吸附按鼠标位置选择显示器而不是窗口所在显示器")
func snapResolverPicksScreenUnderPointer() {
    let screens = [
        CGRect(x: 0, y: 0, width: 1000, height: 800),
        CGRect(x: 1000, y: 0, width: 1600, height: 1000)
    ]

    #expect(WindowSnapResolver.screenIndex(for: CGPoint(x: 500, y: 400), screens: screens) == 0)
    #expect(WindowSnapResolver.screenIndex(for: CGPoint(x: 1100, y: 900), screens: screens) == 1)
    #expect(WindowSnapResolver.screenIndex(for: CGPoint(x: 3000, y: 400), screens: screens) == nil)
}

@Test("鼠标停在显示器边界线上时仍能命中该显示器")
func snapResolverAcceptsEdgeCoordinates() {
    let screens = [CGRect(x: 0, y: 0, width: 1200, height: 800)]

    // 屏幕顶边与右边是常见释放点，CGRect.contains 的半开区间会漏判。
    #expect(WindowSnapResolver.screenIndex(for: CGPoint(x: 600, y: 800), screens: screens) == 0)
    #expect(WindowSnapResolver.screenIndex(for: CGPoint(x: 1200, y: 400), screens: screens) == 0)
    #expect(WindowSnapResolver.screenIndex(for: CGPoint(x: -1, y: 400), screens: screens) == 0)
}

@Test("靠近边缘但落在显示器外时按最近的显示器吸附")
func snapResolverFallsBackToNearestScreen() {
    let screens = [
        CGRect(x: 0, y: 0, width: 1000, height: 800),
        CGRect(x: 1000, y: 0, width: 1600, height: 1000)
    ]

    #expect(WindowSnapResolver.screenIndex(for: CGPoint(x: 500, y: 900), screens: screens) == 0)
    #expect(WindowSnapResolver.screenIndex(for: CGPoint(x: 2700, y: 500), screens: screens) == 1)
    #expect(WindowSnapResolver.screenIndex(for: CGPoint(x: 9000, y: 9000), screens: screens) == nil)
}

// MARK: - 按应用的窗口帧记忆

@Test("窗口帧记忆按应用隔离并可跨实例读回")
func frameMemoryIsolatesApplicationsAndPersists() throws {
    let suiteName = "MenuTools-WindowFrameMemoryTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let memory = WindowFrameMemory(defaults: defaults)
    #expect(memory.previousFrame(for: "com.example.A") == nil)

    let frameA = CGRect(x: 10, y: 20, width: 300, height: 400)
    let frameB = CGRect(x: 1, y: 2, width: 30, height: 40)
    memory.rememberPreviousFrame(frameA, for: "com.example.A")
    memory.rememberPreviousFrame(frameB, for: "com.example.B")

    #expect(memory.previousFrame(for: "com.example.A") == frameA)
    #expect(memory.previousFrame(for: "com.example.B") == frameB)

    let reloaded = WindowFrameMemory(defaults: defaults)
    #expect(reloaded.previousFrame(for: "com.example.A") == frameA)
}

@Test("自动记住的上一帧与手动保存的尺寸互不覆盖")
func frameMemoryKeepsAutomaticAndManualFramesApart() throws {
    let suiteName = "MenuTools-WindowFrameMemoryTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let memory = WindowFrameMemory(defaults: defaults)
    let manual = CGRect(x: 0, y: 0, width: 800, height: 600)
    let automatic = CGRect(x: 100, y: 100, width: 500, height: 400)

    memory.saveFrame(manual, for: "com.example.A")
    memory.rememberPreviousFrame(automatic, for: "com.example.A")
    memory.rememberPreviousFrame(CGRect(x: 200, y: 200, width: 300, height: 300), for: "com.example.A")

    #expect(memory.savedFrame(for: "com.example.A") == manual)
    #expect(memory.previousFrame(for: "com.example.A") == CGRect(x: 200, y: 200, width: 300, height: 300))
}

@Test("窗口帧记忆只保留最近使用的若干个应用")
func frameMemoryEvictsLeastRecentlyUsedApplications() throws {
    let suiteName = "MenuTools-WindowFrameMemoryTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let memory = WindowFrameMemory(defaults: defaults, limit: 2)
    memory.rememberPreviousFrame(CGRect(x: 1, y: 1, width: 10, height: 10), for: "com.example.A")
    memory.rememberPreviousFrame(CGRect(x: 2, y: 2, width: 10, height: 10), for: "com.example.B")
    // 触碰 A，让 B 成为最久未使用者。
    memory.rememberPreviousFrame(CGRect(x: 3, y: 3, width: 10, height: 10), for: "com.example.A")
    memory.rememberPreviousFrame(CGRect(x: 4, y: 4, width: 10, height: 10), for: "com.example.C")

    #expect(memory.previousFrame(for: "com.example.A") != nil)
    #expect(memory.previousFrame(for: "com.example.C") != nil)
    #expect(memory.previousFrame(for: "com.example.B") == nil)
}

// MARK: - 多窗口排列策略

@Test("多窗口排列跳过全屏与最小化窗口并保留输入顺序")
func arrangementPolicyFiltersUnmanageableWindows() {
    let candidates = [
        WindowArrangementCandidate(frame: CGRect(x: 0, y: 400, width: 400, height: 400), isFullScreen: false, isMinimized: false),
        WindowArrangementCandidate(frame: CGRect(x: 0, y: 0, width: 400, height: 400), isFullScreen: true, isMinimized: false),
        WindowArrangementCandidate(frame: CGRect(x: 0, y: 0, width: 400, height: 400), isFullScreen: false, isMinimized: true)
    ]

    #expect(WindowArrangementPolicy.manageableIndices(in: candidates) == [0])
}

@Test("多窗口排列按屏幕阅读顺序排序")
func arrangementPolicySortsByReadingOrder() {
    let candidates = [
        WindowArrangementCandidate(frame: CGRect(x: 800, y: 400, width: 400, height: 400), isFullScreen: false, isMinimized: false),
        WindowArrangementCandidate(frame: CGRect(x: 0, y: 0, width: 400, height: 400), isFullScreen: false, isMinimized: false),
        WindowArrangementCandidate(frame: CGRect(x: 0, y: 400, width: 400, height: 400), isFullScreen: false, isMinimized: false)
    ]

    // 先上后下、同一行内从左到右。
    #expect(WindowArrangementPolicy.orderedIndices(in: candidates) == [2, 0, 1])
}

// MARK: - 挪步步长

@Test("挪步步长可配置并支持修饰键精调")
func nudgeOffsetUsesConfiguredStep() {
    #expect(WindowNudge.offset(step: 20, isFine: false) == 20)
    #expect(WindowNudge.offset(step: 20, isFine: true) == 4)
    #expect(WindowNudge.offset(step: 2, isFine: true) == 1)
}

// MARK: - 吸附预览

@Test("拖拽到屏幕边缘时给出预览落点")
func snapPreviewPlannerProvidesFrame() throws {
    let screens = [WindowSnapScreen(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))]
    let options = WindowManagerOptions(screenPadding: 10, windowGap: 0)

    let left = try #require(WindowSnapPreviewPlanner.plan(
        for: CGPoint(x: 4, y: 400),
        screens: screens,
        options: options
    ))
    #expect(left.layout == .leftHalf)
    #expect(left.frame.minX == 10)
    #expect(left.frame.width == 590)
    #expect(left.frame.height == 780)

    #expect(WindowSnapPreviewPlanner.plan(
        for: CGPoint(x: 600, y: 400),
        screens: screens,
        options: options
    ) == nil)
}

@Test("预览落点在多显示器下使用鼠标所在的显示器")
func snapPreviewPlannerUsesScreenUnderPointer() throws {
    let screens = [
        WindowSnapScreen(frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
        WindowSnapScreen(frame: CGRect(x: 1000, y: 0, width: 1600, height: 1000))
    ]
    let options = WindowManagerOptions(screenPadding: 0, windowGap: 0)

    let plan = try #require(WindowSnapPreviewPlanner.plan(
        for: CGPoint(x: 1004, y: 500),
        screens: screens,
        options: options
    ))
    #expect(plan.layout == .leftHalf)
    #expect(plan.screenIndex == 1)
    #expect(plan.frame.minX == 1000)
    #expect(plan.frame.width == 800)
}

@Test("命中判定用完整屏幕范围，落点用可用区域")
func snapPreviewSeparatesHitTestFromLayoutArea() throws {
    let screen = WindowSnapScreen(
        frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 775)
    )
    let options = WindowManagerOptions(screenPadding: 0, windowGap: 0)

    // 鼠标贴在屏幕最上方（菜单栏所在区域）也要能触发吸顶预览，但窗口不能盖住菜单栏。
    let plan = try #require(WindowSnapPreviewPlanner.plan(
        for: CGPoint(x: 600, y: 799),
        screens: [screen],
        options: options
    ))
    #expect(plan.layout == .topHalf)
    #expect(plan.frame.maxY == 775)
    #expect(plan.frame.height == 387.5)
}

// MARK: - 配置向后兼容

@Test("旧版本配置缺少新增字段时仍能解码并保留已有设置")
func windowManagerConfigurationDecodesLegacyPayload() throws {
    // 1.1.0 之前写入的 JSON：没有 nudgeStep、cycleLayouts、showSnapPreview。
    let legacy = """
    {
      "options": {
        "screenPadding": 12,
        "windowGap": 10,
        "snapDistance": 30,
        "defaultWindowWidth": 900,
        "defaultWindowHeight": 650
      },
      "presets": [],
      "applicationRules": [],
      "excludedBundleIdentifiers": ["com.example.Terminal"],
      "automaticApplicationRules": true,
      "edgeSnappingEnabled": true
    }
    """

    let decoded = try JSONDecoder().decode(WindowManagerConfiguration.self, from: Data(legacy.utf8))

    #expect(decoded.options.screenPadding == 12)
    #expect(decoded.options.snapDistance == 30)
    #expect(decoded.options.nudgeStep == WindowManagerOptions().nudgeStep)
    #expect(decoded.excludedBundleIdentifiers == ["com.example.Terminal"])
    #expect(decoded.edgeSnappingEnabled)
    #expect(decoded.cycleLayouts == WindowManagerConfiguration().cycleLayouts)
    #expect(decoded.showSnapPreview == WindowManagerConfiguration().showSnapPreview)
}
