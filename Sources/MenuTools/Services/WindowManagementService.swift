import ApplicationServices
import AppKit
import Foundation
import Observation

enum WindowLayout: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case leftHalf
    case rightHalf
    case maxWidth
    case maxHeight
    case maximize
    case toggleFullscreen
    case almostMaximize
    case reasonableSize
    case makeLarger
    case makeSmaller
    case restore
    case topHalf
    case bottomHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case topLeftSixth
    case topCenterSixth
    case topRightSixth
    case bottomLeftSixth
    case bottomCenterSixth
    case bottomRightSixth
    case firstThird
    case centerThird
    case lastThird
    case firstTwoThirds
    case centerTwoThirds
    case lastTwoThirds
    case firstThreeFourths
    case centerThreeFourths
    case lastThreeFourths
    case firstFourth
    case secondFourth
    case thirdFourth
    case lastFourth
    case topThird
    case middleThird
    case bottomThird
    case topTwoThirds
    case bottomTwoThirds
    case topThreeFourths
    case bottomThreeFourths
    case topFirstFourth
    case topSecondFourth
    case topThirdFourth
    case topLastFourth
    case topCenterTwoThirds
    case bottomCenterTwoThirds
    case centered
    case moveNextDisplay
    case movePreviousDisplay
    case moveNextDesktop
    case movePreviousDesktop
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case stashLeft
    case stashRight

    var id: String { rawValue }
    var titleKey: String { "window.\(rawValue)" }
    /// 收纳：把窗口推到屏幕边缘外，只留一条可见边，便于临时让出屏幕空间。
    var isStash: Bool {
        switch self {
        case .stashLeft, .stashRight: return true
        default: return false
        }
    }
    var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .maxWidth: return "arrow.left.and.right"
        case .maxHeight: return "arrow.up.and.down"
        case .maximize: return "rectangle.fill"
        case .toggleFullscreen: return "arrow.up.left.and.arrow.down.right"
        case .almostMaximize: return "rectangle.inset.filled"
        case .reasonableSize: return "rectangle.center.inset.filled"
        case .makeLarger: return "plus"
        case .makeSmaller: return "minus"
        case .restore: return "arrow.uturn.backward"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .topLeftSixth: return "rectangle.inset.topleft.filled"
        case .topCenterSixth: return "rectangle.center.inset.filled"
        case .topRightSixth: return "rectangle.inset.topright.filled"
        case .bottomLeftSixth: return "rectangle.inset.bottomleft.filled"
        case .bottomCenterSixth: return "rectangle.center.inset.filled"
        case .bottomRightSixth: return "rectangle.inset.bottomright.filled"
        case .firstThird, .firstTwoThirds, .firstThreeFourths: return "rectangle.lefthalf.filled"
        case .centerThird, .centerTwoThirds, .centerThreeFourths: return "rectangle.center.inset.filled"
        case .lastThird, .lastTwoThirds, .lastThreeFourths: return "rectangle.righthalf.filled"
        case .firstFourth: return "rectangle.lefthalf.filled"
        case .secondFourth: return "rectangle.center.inset.filled"
        case .thirdFourth: return "rectangle.center.inset.filled"
        case .lastFourth: return "rectangle.righthalf.filled"
        case .topThird, .topTwoThirds, .topThreeFourths: return "rectangle.tophalf.filled"
        case .middleThird: return "rectangle.center.inset.filled"
        case .bottomThird, .bottomTwoThirds, .bottomThreeFourths: return "rectangle.bottomhalf.filled"
        case .topFirstFourth: return "rectangle.inset.topleft.filled"
        case .topSecondFourth: return "rectangle.tophalf.filled"
        case .topThirdFourth: return "rectangle.tophalf.filled"
        case .topLastFourth: return "rectangle.inset.topright.filled"
        case .topCenterTwoThirds, .bottomCenterTwoThirds:
            return "rectangle.center.inset.filled"
        case .centered: return "rectangle.center.inset.filled"
        case .moveNextDisplay: return "rectangle.on.rectangle.angled"
        case .movePreviousDisplay: return "rectangle.on.rectangle.angled"
        case .moveNextDesktop, .movePreviousDesktop: return "rectangle.on.rectangle"
        case .moveLeft: return "arrow.left"
        case .moveRight: return "arrow.right"
        case .moveUp: return "arrow.up"
        case .moveDown: return "arrow.down"
        case .stashLeft: return "arrow.left.to.line"
        case .stashRight: return "arrow.right.to.line"
        }
    }
}

enum WindowLayoutCalculator {
    static func frame(
        for layout: WindowLayout,
        in screen: CGRect,
        preferredSize: CGSize = CGSize(width: 900, height: 650),
        options: WindowManagerOptions = WindowManagerOptions()
    ) -> CGRect {
        let gap = options.windowGap
        let safe = screen.insetBy(dx: options.screenPadding, dy: options.screenPadding)
        switch layout {
        case .leftHalf:
            return grid(column: 0, columns: 2, row: 0, rows: 1, in: safe, gap: gap)
        case .rightHalf:
            return grid(column: 1, columns: 2, row: 0, rows: 1, in: safe, gap: gap)
        case .maxWidth:
            return centered(preferredSize, in: safe, width: safe.width, height: preferredSize.height)
        case .maxHeight:
            return centered(preferredSize, in: safe, width: preferredSize.width, height: safe.height)
        case .maximize:
            return safe
        case .toggleFullscreen:
            return safe
        case .almostMaximize:
            return safe.insetBy(dx: safe.width * 0.05, dy: safe.height * 0.05)
        case .reasonableSize:
            return centered(CGSize(width: 900, height: 650), in: safe)
        case .makeLarger:
            return resized(preferredSize, by: 1.1, in: safe)
        case .makeSmaller:
            return resized(preferredSize, by: 0.9, in: safe)
        case .restore,
             .moveNextDisplay, .movePreviousDisplay,
             .moveNextDesktop, .movePreviousDesktop,
             .moveLeft, .moveRight, .moveUp, .moveDown:
            return centered(preferredSize, in: safe)
        case .topHalf:
            return grid(column: 0, columns: 1, row: 0, rows: 2, in: safe, gap: gap)
        case .bottomHalf:
            return grid(column: 0, columns: 1, row: 1, rows: 2, in: safe, gap: gap)
        case .topLeft:
            return grid(column: 0, columns: 2, row: 0, rows: 2, in: safe, gap: gap)
        case .topRight:
            return grid(column: 1, columns: 2, row: 0, rows: 2, in: safe, gap: gap)
        case .bottomLeft:
            return grid(column: 0, columns: 2, row: 1, rows: 2, in: safe, gap: gap)
        case .bottomRight:
            return grid(column: 1, columns: 2, row: 1, rows: 2, in: safe, gap: gap)
        case .topLeftSixth:
            return grid(column: 0, columns: 3, row: 0, rows: 2, in: safe, gap: gap)
        case .topCenterSixth:
            return grid(column: 1, columns: 3, row: 0, rows: 2, in: safe, gap: gap)
        case .topRightSixth:
            return grid(column: 2, columns: 3, row: 0, rows: 2, in: safe, gap: gap)
        case .bottomLeftSixth:
            return grid(column: 0, columns: 3, row: 1, rows: 2, in: safe, gap: gap)
        case .bottomCenterSixth:
            return grid(column: 1, columns: 3, row: 1, rows: 2, in: safe, gap: gap)
        case .bottomRightSixth:
            return grid(column: 2, columns: 3, row: 1, rows: 2, in: safe, gap: gap)
        case .firstThird:
            return grid(column: 0, columns: 3, row: 0, rows: 1, in: safe, gap: gap)
        case .centerThird:
            return grid(column: 1, columns: 3, row: 0, rows: 1, in: safe, gap: gap)
        case .lastThird:
            return grid(column: 2, columns: 3, row: 0, rows: 1, in: safe, gap: gap)
        case .firstTwoThirds:
            return span(column: 0, columnSpan: 2, columns: 3, row: 0, rowSpan: 1, rows: 1, in: safe, gap: gap)
        case .centerTwoThirds:
            return centered(preferredSize, in: safe, width: safe.width * 2 / 3, height: safe.height)
        case .lastTwoThirds:
            return span(column: 1, columnSpan: 2, columns: 3, row: 0, rowSpan: 1, rows: 1, in: safe, gap: gap)
        case .firstThreeFourths:
            return span(column: 0, columnSpan: 3, columns: 4, row: 0, rowSpan: 1, rows: 1, in: safe, gap: gap)
        case .centerThreeFourths:
            return centered(preferredSize, in: safe, width: safe.width * 3 / 4, height: safe.height)
        case .lastThreeFourths:
            return span(column: 1, columnSpan: 3, columns: 4, row: 0, rowSpan: 1, rows: 1, in: safe, gap: gap)
        case .firstFourth:
            return grid(column: 0, columns: 4, row: 0, rows: 1, in: safe, gap: gap)
        case .secondFourth:
            return grid(column: 1, columns: 4, row: 0, rows: 1, in: safe, gap: gap)
        case .thirdFourth:
            return grid(column: 2, columns: 4, row: 0, rows: 1, in: safe, gap: gap)
        case .lastFourth:
            return grid(column: 3, columns: 4, row: 0, rows: 1, in: safe, gap: gap)
        case .topThird:
            return span(column: 0, columnSpan: 1, columns: 1, row: 0, rowSpan: 1, rows: 3, in: safe, gap: gap)
        case .middleThird:
            return span(column: 0, columnSpan: 1, columns: 1, row: 1, rowSpan: 1, rows: 3, in: safe, gap: gap)
        case .bottomThird:
            return span(column: 0, columnSpan: 1, columns: 1, row: 2, rowSpan: 1, rows: 3, in: safe, gap: gap)
        case .topTwoThirds:
            return span(column: 0, columnSpan: 1, columns: 1, row: 0, rowSpan: 2, rows: 3, in: safe, gap: gap)
        case .bottomTwoThirds:
            return span(column: 0, columnSpan: 1, columns: 1, row: 1, rowSpan: 2, rows: 3, in: safe, gap: gap)
        case .topThreeFourths:
            return span(column: 0, columnSpan: 1, columns: 1, row: 0, rowSpan: 3, rows: 4, in: safe, gap: gap)
        case .bottomThreeFourths:
            return span(column: 0, columnSpan: 1, columns: 1, row: 1, rowSpan: 3, rows: 4, in: safe, gap: gap)
        case .topFirstFourth:
            return grid(column: 0, columns: 4, row: 0, rows: 2, in: safe, gap: gap)
        case .topSecondFourth:
            return grid(column: 1, columns: 4, row: 0, rows: 2, in: safe, gap: gap)
        case .topThirdFourth:
            return grid(column: 2, columns: 4, row: 0, rows: 2, in: safe, gap: gap)
        case .topLastFourth:
            return grid(column: 3, columns: 4, row: 0, rows: 2, in: safe, gap: gap)
        case .topCenterTwoThirds:
            return centeredGrid(widthFraction: 2 / 3, row: 0, rows: 2, in: safe, gap: gap)
        case .bottomCenterTwoThirds:
            return centeredGrid(widthFraction: 2 / 3, row: 1, rows: 2, in: safe, gap: gap)
        case .centered:
            return centered(preferredSize, in: safe)
        case .stashLeft:
            return stashed(preferredSize, in: safe, edgeIsLeading: true)
        case .stashRight:
            return stashed(preferredSize, in: safe, edgeIsLeading: false)
        }
    }

    /// 收纳后仍停留在屏幕内的可见宽度。
    static let stashVisibleStrip: CGFloat = 16

    private static func stashed(_ size: CGSize, in screen: CGRect, edgeIsLeading: Bool) -> CGRect {
        let width = min(max(size.width, 1), screen.width)
        let height = min(max(size.height, 1), screen.height)
        let x = edgeIsLeading
            ? screen.minX - width + stashVisibleStrip
            : screen.maxX - stashVisibleStrip
        let y = min(max(screen.midY - height / 2, screen.minY), screen.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func grid(column: Int, columns: Int, row: Int, rows: Int, in screen: CGRect, gap: CGFloat) -> CGRect {
        span(column: column, columnSpan: 1, columns: columns, row: row, rowSpan: 1, rows: rows, in: screen, gap: gap)
    }

    private static func span(
        column: Int,
        columnSpan: Int,
        columns: Int,
        row: Int,
        rowSpan: Int,
        rows: Int,
        in screen: CGRect,
        gap: CGFloat
    ) -> CGRect {
        let columnWidth = (screen.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let rowHeight = (screen.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        let x = screen.minX + CGFloat(column) * (columnWidth + gap)
        let y = screen.maxY - CGFloat(row + rowSpan) * rowHeight - CGFloat(row + rowSpan - 1) * gap
        return CGRect(
            x: x,
            y: y,
            width: columnWidth * CGFloat(columnSpan) + gap * CGFloat(columnSpan - 1),
            height: rowHeight * CGFloat(rowSpan) + gap * CGFloat(rowSpan - 1)
        )
    }

    private static func centered(_ size: CGSize, in screen: CGRect, width: CGFloat? = nil, height: CGFloat? = nil) -> CGRect {
        let target = CGSize(
            width: min(width ?? size.width, screen.width),
            height: min(height ?? size.height, screen.height)
        )
        return CGRect(x: screen.midX - target.width / 2, y: screen.midY - target.height / 2, width: target.width, height: target.height)
    }

    private static func resized(_ size: CGSize, by factor: CGFloat, in screen: CGRect) -> CGRect {
        centered(CGSize(width: size.width * factor, height: size.height * factor), in: screen)
    }

    private static func centeredGrid(widthFraction: CGFloat, row: Int, rows: Int, in screen: CGRect, gap: CGFloat) -> CGRect {
        let rowHeight = (screen.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        let width = screen.width * widthFraction
        let y = screen.maxY - CGFloat(row + 1) * rowHeight - CGFloat(row) * gap
        return CGRect(x: screen.midX - width / 2, y: y, width: width, height: rowHeight)
    }
}

/// 在 NSScreen 的左下角原点和辅助功能 API 的左上角原点之间转换窗口坐标。
enum WindowCoordinateConverter {
    static func toAccessibility(_ frame: CGRect, desktopTop: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: desktopTop - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func fromAccessibility(_ frame: CGRect, desktopTop: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: desktopTop - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}

enum WindowTargetResolver {
    static func preferredProcessIdentifier(
        frontmost: pid_t?,
        remembered: pid_t?,
        own: pid_t
    ) -> pid_t? {
        if let frontmost, frontmost != own {
            return frontmost
        }
        if let remembered, remembered != own {
            return remembered
        }
        return nil
    }
}

enum WindowManagementError: LocalizedError, Equatable {
    case noFocusedWindow
    case excludedApplication
    case accessibilityPermission
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFocusedWindow: return L("window.error.noWindow")
        case .excludedApplication: return L("window.error.excludedApplication")
        case .accessibilityPermission: return L("window.error.permission")
        case let .operationFailed(message): return L("window.error.operation", message)
        }
    }
}

struct WindowApplicationInfo: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let name: String
}

@MainActor
@Observable
final class WindowManagementService {
    static let shared = WindowManagementService()

    private(set) var configuration: WindowManagerConfiguration
    private(set) var lastSavedFrame: CGRect?
    private var lastExternalApplicationPID: pid_t?
    private var activationObserver: NSObjectProtocol?
    private let defaults: UserDefaults
    private let frameMemory: WindowFrameMemory
    private let snapPreview = WindowSnapPreviewController()
    private var cycleState = WindowLayoutCycleState()
    private var traversalTracker = WindowRepeatTracker()
    private var stashToggleTracker = WindowRepeatTracker()
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var mouseDownLocation: CGPoint?
    /// 拖拽开始瞬间的目标窗口位置，用来区分「拖动窗口」和「划选文字」。
    private var dragWindowFrameAtMouseDown: CGRect?
    /// 命中测试定位到的拖拽目标窗口（比“前台应用的焦点窗口”可靠）。
    private var dragWindow: AXUIElement?
    private var dragWindowPID: pid_t?
    private var dragWindowLookupAttempts = 0
    private var lastDragWindowLookup: TimeInterval = 0
    private var lastDragEventLog: TimeInterval = 0
    /// 上一次展示的落点预览，用于判断是否进入了新的吸附区域（决定要不要给触觉反馈）。
    private var lastPreviewPlan: WindowSnapPreviewPlan?
    /// 最近一次由 MenuTools 套用的窗口帧（按应用），用于「拖出已吸附窗口恢复原尺寸」。
    private var lastAppliedFrames: [String: CGRect] = [:]
    private var unsnapHandledForCurrentDrag = false
    /// 按下点是否落在标题栏/工具栏区域——只有这里才是“拖动窗口”，正文区域是划选内容。
    private var dragStartedInWindowChrome = false
    /// 拖拽预览读取 AX 的限流时间戳。
    private var lastSnapProbeTime: TimeInterval = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.frameMemory = WindowFrameMemory(defaults: defaults)
        self.configuration = Self.loadConfiguration(from: defaults)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let processIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor [weak self] in
                self?.rememberExternalApplication(processIdentifier: processIdentifier)
                self?.applyAutomaticRuleIfNeeded(processIdentifier: processIdentifier)
            }
        }
        rememberFrontmostExternalApplication()
    }

    func start() {
        SnapDebugLog.log("start(): edgeSnapping=\(configuration.edgeSnappingEnabled) showSnapPreview=\(configuration.showSnapPreview) snapDistance=\(configuration.options.snapDistance) screens=\(NSScreen.screens.count)")
        refreshMouseMonitors()
    }

    func stop() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        resetDragState()
        hideSnapPreview()
        cycleState.reset()
        traversalTracker.reset()
        stashToggleTracker.reset()
    }

    func updateOptions(_ options: WindowManagerOptions) {
        configuration.options = options
        saveConfiguration()
    }

    func setEdgeSnappingEnabled(_ enabled: Bool) {
        configuration.edgeSnappingEnabled = enabled
        saveConfiguration()
        refreshMouseMonitors()
        if !enabled { hideSnapPreview() }
    }

    func setCycleLayoutsEnabled(_ enabled: Bool) {
        configuration.cycleLayouts = enabled
        saveConfiguration()
        cycleState.reset()
    }

    func setSnapPreviewEnabled(_ enabled: Bool) {
        configuration.showSnapPreview = enabled
        saveConfiguration()
        if !enabled { hideSnapPreview() }
    }

    func setHapticFeedbackEnabled(_ enabled: Bool) {
        configuration.hapticFeedbackOnSnap = enabled
        saveConfiguration()
    }

    /// 自定义某个吸附区域触发的布局；传 nil 表示恢复该区域的内置动作。
    func setSnapAreaAction(_ layout: WindowLayout?, for area: WindowSnapArea) {
        configuration.snapAreaMapping.setOverride(layout, for: area)
        saveConfiguration()
        hideSnapPreview()
    }

    func resetSnapAreaMapping() {
        configuration.snapAreaMapping.removeAll()
        saveConfiguration()
        hideSnapPreview()
    }

    func setDetailedSnapAreasEnabled(_ enabled: Bool) {
        configuration.detailedSnapAreas = enabled
        saveConfiguration()
        hideSnapPreview()
    }

    func setRestoreSizeOnDragOutEnabled(_ enabled: Bool) {
        configuration.restoreSizeWhenDraggingOut = enabled
        saveConfiguration()
    }

    func setTraverseDisplaysEnabled(_ enabled: Bool) {
        configuration.traverseDisplaysOnRepeat = enabled
        saveConfiguration()
        // 开关状态变化后重新计数，避免用旧状态判定“连按”。
        traversalTracker.reset()
    }

    func setAutomaticApplicationRulesEnabled(_ enabled: Bool) {
        configuration.automaticApplicationRules = enabled
        saveConfiguration()
    }

    func addPreset(name: String, layout: WindowLayout) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        configuration.presets.append(WindowLayoutPreset(name: trimmedName, layout: layout))
        saveConfiguration()
    }

    func removePreset(_ preset: WindowLayoutPreset) {
        configuration.presets.removeAll { $0.id == preset.id }
        saveConfiguration()
    }

    func addOrUpdateApplicationRule(
        for application: WindowApplicationInfo,
        layout: WindowLayout,
        windowTitleContains: String? = nil,
        firstWindowOnly: Bool = false
    ) {
        let trimmedFilter = windowTitleContains?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = WindowApplicationRule(
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.name,
            layout: layout,
            windowTitleContains: (trimmedFilter?.isEmpty ?? true) ? nil : trimmedFilter,
            firstWindowOnly: firstWindowOnly
        )
        if let index = configuration.applicationRules.firstIndex(where: { $0.bundleIdentifier == rule.bundleIdentifier }) {
            configuration.applicationRules[index] = rule
        } else {
            configuration.applicationRules.append(rule)
        }
        saveConfiguration()
    }

    func setApplicationRuleEnabled(_ enabled: Bool, for rule: WindowApplicationRule) {
        guard let index = configuration.applicationRules.firstIndex(where: { $0.id == rule.id }) else { return }
        configuration.applicationRules[index].isEnabled = enabled
        saveConfiguration()
    }

    func removeApplicationRule(_ rule: WindowApplicationRule) {
        configuration.applicationRules.removeAll { $0.id == rule.id }
        saveConfiguration()
    }

    func addExcludedApplication(_ application: WindowApplicationInfo) {
        guard !configuration.excludedBundleIdentifiers.contains(application.bundleIdentifier) else { return }
        configuration.excludedBundleIdentifiers.append(application.bundleIdentifier)
        saveConfiguration()
    }

    func removeExcludedApplication(_ bundleIdentifier: String) {
        configuration.excludedBundleIdentifiers.removeAll { $0 == bundleIdentifier }
        saveConfiguration()
    }

    func focusedApplicationInfo() -> WindowApplicationInfo? {
        guard let processIdentifier = try? externalProcessIdentifier(),
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              let bundleIdentifier = application.bundleIdentifier else { return nil }
        return WindowApplicationInfo(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            name: application.localizedName ?? bundleIdentifier
        )
    }

    /// 在菜单栏面板或设置窗口激活前记录当前真正要管理的外部应用。
    func rememberFrontmostExternalApplication() {
        rememberExternalApplication(processIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    private func rememberExternalApplication(processIdentifier: pid_t?) {
        guard let processIdentifier,
              processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApplicationPID = processIdentifier
    }

    func apply(_ layout: WindowLayout) throws {
        guard AXIsProcessTrusted() else { throw WindowManagementError.accessibilityPermission }
        let processIdentifier = try externalProcessIdentifier()
        guard !isExcluded(processIdentifier: processIdentifier) else {
            throw WindowManagementError.excludedApplication
        }
        let window = try focusedWindow(of: processIdentifier)
        switch layout {
        case .restore:
            try restoreFocusedWindowFrame()
            return
        case .toggleFullscreen:
            try toggleFullscreen(window: window)
            return
        case .moveNextDisplay:
            try move(window: window, displayOffset: 1)
            return
        case .movePreviousDisplay:
            try move(window: window, displayOffset: -1)
            return
        case .moveNextDesktop:
            postDesktopShortcut(keyCode: 124)
            return
        case .movePreviousDesktop:
            postDesktopShortcut(keyCode: 123)
            return
        case .moveLeft:
            try nudge(window: window, dx: -nudgeDistance, dy: 0)
            return
        case .moveRight:
            try nudge(window: window, dx: nudgeDistance, dy: 0)
            return
        case .moveUp:
            try nudge(window: window, dx: 0, dy: nudgeDistance)
            return
        case .moveDown:
            try nudge(window: window, dx: 0, dy: -nudgeDistance)
            return
        default:
            break
        }
        let screen = screen(for: window) ?? NSScreen.main?.visibleFrame ?? .zero
        guard !screen.isEmpty else { throw WindowManagementError.operationFailed(L("window.error.noScreen")) }
        let targetKey = cycleTargetKey(processIdentifier: processIdentifier, window: window)

        // 收纳：再次触发同一方向即收回（Loop 式的收纳／收回切换）。
        if layout.isStash {
            if stashToggleTracker.isRepeat(layout: layout, targetKey: targetKey),
               frameMemory.previousFrame(for: bundleIdentifier(for: processIdentifier)) != nil {
                try restoreFocusedWindowFrame()
                return
            }
        } else {
            stashToggleTracker.reset()
        }

        let target = resolvedLayout(layout, targetKey: targetKey)
        // 连按半屏布局：把窗口带到相邻显示器再套用同一布局（对标 Rectangle 的跨显示器遍历）。
        if configuration.traverseDisplaysOnRepeat,
           let offset = WindowDisplayTraversal.displayOffset(for: target),
           traversalTracker.isRepeat(layout: target, targetKey: targetKey) {
            rememberFrameBeforeLayout(of: window, processIdentifier: processIdentifier)
            try applyOnAdjacentDisplay(target, window: window, offset: offset, processIdentifier: processIdentifier)
            return
        }
        rememberFrameBeforeLayout(of: window, processIdentifier: processIdentifier)
        let frame = WindowLayoutCalculator.frame(
            for: target,
            in: screen,
            preferredSize: currentSize(of: window),
            options: configuration.options
        )
        try setFrame(frame, of: window)
        recordAppliedFrame(frame, processIdentifier: processIdentifier)
    }

    /// 把窗口移到相邻显示器，再在新显示器上套用同一布局。
    private func applyOnAdjacentDisplay(
        _ layout: WindowLayout,
        window: AXUIElement,
        offset: Int,
        processIdentifier: pid_t
    ) throws {
        try move(window: window, displayOffset: offset)
        guard let screen = screen(for: window) else {
            throw WindowManagementError.operationFailed(L("window.error.noScreen"))
        }
        let frame = WindowLayoutCalculator.frame(
            for: layout,
            in: screen,
            preferredSize: currentSize(of: window),
            options: configuration.options
        )
        try setFrame(frame, of: window)
        recordAppliedFrame(frame, processIdentifier: processIdentifier)
    }

    /// 应用固定尺寸预设：先把记录帧夹取回当前显示器，再写入窗口。
    func apply(_ preset: WindowLayoutPreset) throws {
        if let frame = preset.frame {
            guard AXIsProcessTrusted() else { throw WindowManagementError.accessibilityPermission }
            let processIdentifier = try externalProcessIdentifier()
            guard !isExcluded(processIdentifier: processIdentifier) else {
                throw WindowManagementError.excludedApplication
            }
            let window = try focusedWindow(of: processIdentifier)
            rememberFrameBeforeLayout(of: window, processIdentifier: processIdentifier)
            let target = WindowFrameClamper.clamp(frame, into: NSScreen.screens.map(\.visibleFrame))
            try setFrame(target, of: window)
            recordAppliedFrame(target, processIdentifier: processIdentifier)
        } else {
            try apply(preset.layout)
        }
    }

    /// 把当前窗口的位置与尺寸保存为固定尺寸预设。
    @discardableResult
    func capturePreset(name: String) throws -> WindowLayoutPreset {
        guard AXIsProcessTrusted() else { throw WindowManagementError.accessibilityPermission }
        let processIdentifier = try externalProcessIdentifier()
        guard !isExcluded(processIdentifier: processIdentifier) else {
            throw WindowManagementError.excludedApplication
        }
        let window = try focusedWindow(of: processIdentifier)
        guard let preset = WindowPresetFactory.preset(name: name, frame: try cocoaFrame(of: window)) else {
            throw WindowManagementError.operationFailed(L("window.error.presetName"))
        }
        configuration.presets.append(preset)
        saveConfiguration()
        return preset
    }

    @discardableResult
    func arrangeFocusedApplicationWindows() throws -> Int {
        guard AXIsProcessTrusted() else { throw WindowManagementError.accessibilityPermission }
        let processIdentifier = try externalProcessIdentifier()
        guard !isExcluded(processIdentifier: processIdentifier) else {
            throw WindowManagementError.excludedApplication
        }
        let application = AXUIElementCreateApplication(processIdentifier)
        let elements = try windowElements(of: application)
        // 全屏窗口不参与网格排列，否则会被从全屏空间里拽出来；顺序按屏幕阅读顺序稳定下来。
        let candidates = elements.map { arrangementCandidate(of: $0) }
        let windows = WindowArrangementPolicy.orderedIndices(in: candidates).map { elements[$0] }
        guard !windows.isEmpty else { throw WindowManagementError.noFocusedWindow }
        let screen = screen(for: windows[0]) ?? NSScreen.main?.visibleFrame ?? .zero
        guard !screen.isEmpty else { throw WindowManagementError.operationFailed(L("window.error.noScreen")) }
        let frames = WindowArrangementCalculator.frames(for: windows.count, in: screen, options: configuration.options)
        for (window, frame) in zip(windows, frames) {
            rememberFrameBeforeLayout(of: window, processIdentifier: processIdentifier)
            try setFrame(frame, of: window)
        }
        return windows.count
    }

    /// 手动记住当前窗口尺寸（按应用分别保存）。
    func saveFocusedWindowFrame() throws {
        guard AXIsProcessTrusted() else { throw WindowManagementError.accessibilityPermission }
        let processIdentifier = try externalProcessIdentifier()
        let window = try focusedWindow(of: processIdentifier)
        let frame = try cocoaFrame(of: window)
        lastSavedFrame = frame
        frameMemory.saveFrame(frame, for: bundleIdentifier(for: processIdentifier))
    }

    /// 还原窗口尺寸。
    ///
    /// 优先回到「上一次布局前」的位置（自动记录，用户无需先手动记住），其次才是手动记住的尺寸，
    /// 最后兼容 1.1.0 之前写入的全局尺寸记录。
    func restoreFocusedWindowFrame() throws {
        guard AXIsProcessTrusted() else { throw WindowManagementError.accessibilityPermission }
        let processIdentifier = try externalProcessIdentifier()
        let window = try focusedWindow(of: processIdentifier)
        let bundleIdentifier = bundleIdentifier(for: processIdentifier)
        if let frame = frameMemory.previousFrame(for: bundleIdentifier) ?? frameMemory.savedFrame(for: bundleIdentifier) {
            try setFrame(frame, of: window)
            return
        }
        guard let legacy = legacySavedFrame() else {
            throw WindowManagementError.operationFailed(L("window.error.noSavedFrame"))
        }
        try setFrame(legacy, of: window)
    }

    /// 1.1.0 之前的全局尺寸记录，仅作为兼容回退。
    private func legacySavedFrame() -> CGRect? {
        guard let values = defaults.array(forKey: Self.savedFrameKey) as? [Double], values.count == 4 else {
            return nil
        }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private static let savedFrameKey = "windowManagement.savedFrame"
    private static let configurationKey = "windowManagement.configuration"

    private static func loadConfiguration(from defaults: UserDefaults) -> WindowManagerConfiguration {
        guard let data = defaults.data(forKey: configurationKey),
              let configuration = try? JSONDecoder().decode(WindowManagerConfiguration.self, from: data) else {
            return WindowManagerConfiguration()
        }
        return configuration
    }

    private func saveConfiguration() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.configurationKey)
    }

    private func applyAutomaticRuleIfNeeded(processIdentifier: pid_t?) {
        guard configuration.automaticApplicationRules,
              let processIdentifier,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              let bundleIdentifier = application.bundleIdentifier,
              // 先按 bundle id 粗筛，避免为无关应用起一个延时任务
              WindowApplicationRuleResolver.layout(
                for: bundleIdentifier,
                rules: configuration.applicationRules,
                excludedBundleIdentifiers: configuration.excludedBundleIdentifiers
              ) != nil else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
                  let window = try? self.focusedWindow(of: processIdentifier) else { return }

            // 弹窗/表单不参与自动布局
            guard !WindowApplicationRuleResolver.shouldSkipAutomaticLayout(
                role: self.stringAttribute(kAXRoleAttribute, of: window),
                subrole: self.stringAttribute(kAXSubroleAttribute, of: window)
            ) else { return }

            guard let layout = WindowApplicationRuleResolver.layout(
                for: bundleIdentifier,
                windowTitle: self.windowTitle(of: window),
                rules: self.configuration.applicationRules,
                excludedBundleIdentifiers: self.configuration.excludedBundleIdentifiers
            ) else { return }

            // 「只作用于首个（主）窗口」：焦点在工具面板或次窗口上时不动它
            let firstWindowOnly = self.configuration.applicationRules.first {
                $0.bundleIdentifier == bundleIdentifier && $0.isEnabled
            }?.firstWindowOnly ?? false
            guard WindowApplicationRuleResolver.shouldApplyToFocusedWindow(
                isMainWindow: self.isMainWindow(window, of: processIdentifier),
                firstWindowOnly: firstWindowOnly
            ) else {
                SnapDebugLog.log("auto rule: skipped, focused window is not the main window")
                return
            }
            try? self.apply(layout)
        }
    }

    private func refreshMouseMonitors() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        resetDragState()
        hideSnapPreview()
        guard configuration.edgeSnappingEnabled else {
            SnapDebugLog.log("refreshMouseMonitors: edge snapping disabled, no monitor registered")
            return
        }

        // 需要拖动事件才能在拖拽过程中实时显示落点预览。
        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            let type = event.type
            Task { @MainActor [weak self] in
                self?.handleMouseEvent(type)
            }
        }
        SnapDebugLog.log("refreshMouseMonitors: monitorRegistered=\(globalMouseMonitor != nil) showSnapPreview=\(configuration.showSnapPreview)")
    }

    private func resetDragState() {
        mouseDownLocation = nil
        dragWindow = nil
        dragWindowPID = nil
        dragWindowFrameAtMouseDown = nil
        dragWindowLookupAttempts = 0
        lastDragWindowLookup = 0
        lastSnapProbeTime = 0
        dragStartedInWindowChrome = false
        unsnapHandledForCurrentDrag = false
    }

    private func handleMouseEvent(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            mouseDownLocation = NSEvent.mouseLocation
            lastSnapProbeTime = 0
            dragWindowLookupAttempts = 0
            lastDragWindowLookup = 0
            captureDragWindow(at: NSEvent.mouseLocation)
            SnapDebugLog.log("mouseDown: point=\(NSStringFromPoint(NSEvent.mouseLocation)) windowHit=\(dragWindow != nil) frame=\(dragWindowFrameAtMouseDown.map(NSStringFromRect) ?? "nil") titleBar=\(dragStartedInWindowChrome)")
        case .leftMouseDragged:
            if dragWindow == nil { captureDragWindow(at: NSEvent.mouseLocation) }
            prepareUnsnapRestoreIfNeeded(at: NSEvent.mouseLocation)
            logDragEvent()
            updateSnapPreview(at: NSEvent.mouseLocation)
        case .leftMouseUp:
            let hadWindow = dragWindow != nil
            let startedInChrome = dragStartedInWindowChrome
            hideSnapPreview()
            let end = NSEvent.mouseLocation
            let distance = mouseDownLocation.map { hypot(end.x - $0.x, end.y - $0.y) } ?? 0
            SnapDebugLog.log("mouseUp: point=\(NSStringFromPoint(end)) windowHit=\(hadWindow) startedInTitleBar=\(startedInChrome) dragDistance=\(Int(distance))")
            // 必须带着拖拽窗口调用吸附，所以清理状态放在它之后。
            if distance > 12, startedInChrome {
                snapWindow(at: end)
            }
            resetDragState()
        default:
            break
        }
    }

    /// 记录拖拽事件（限流到约 2 次/秒），用来确认全局监听到底有没有收到 leftMouseDragged。
    private func logDragEvent() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDragEventLog > 0.5 else { return }
        lastDragEventLog = now
        let point = NSEvent.mouseLocation
        SnapDebugLog.log("mouseDragged: windowHit=\(dragWindow != nil) titleBar=\(dragStartedInWindowChrome) point=(\(Int(point.x)),\(Int(point.y)))")
    }

    /// 拖拽过程中显示落点预览。
    ///
    /// 判据是「按下点位于窗口标题栏」+ 指针移动超过阈值，而不是读取 AX 的窗口位置变化：
    /// 很多应用直到拖拽结束才更新位置，用位置变化判断会让预览永远不出现。
    private func updateSnapPreview(at point: CGPoint) {
        guard configuration.edgeSnappingEnabled, configuration.showSnapPreview else {
            hideSnapPreview()
            return
        }
        guard let start = mouseDownLocation,
              hypot(point.x - start.x, point.y - start.y) > 8 else { return }

        // 拖动过程中每个事件都读 AX 会明显增加开销，这里限流到约 12 次/秒。
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSnapProbeTime > 0.08 else { return }
        lastSnapProbeTime = now

        // 不能用“AX 报告的窗口位置变了”当判据：很多应用只在拖拽结束后才更新窗口位置，
        // 拖动过程中读到的一直是旧值，会导致预览永远不出现。按下点是否在标题栏才是可靠信号。
        guard dragStartedInWindowChrome else { return }
        guard let plan = WindowSnapPreviewPlanner.plan(
            for: point,
            windowFrame: dragWindowFrame,
            screens: snapScreens,
            options: configuration.options,
            detailedSnapAreas: configuration.detailedSnapAreas,
            snapAreaMapping: configuration.snapAreaMapping
        ) else {
            hideSnapPreview()
            return
        }
        SnapDebugLog.log("preview: layout=\(plan.layout.rawValue) frame=\(NSStringFromRect(plan.frame))")
        let enteredNewZone = WindowSnapFeedback.shouldTriggerHaptic(previous: lastPreviewPlan, next: plan)
        if enteredNewZone, configuration.hapticFeedbackOnSnap {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        lastPreviewPlan = plan
        snapPreview.show(
            plan,
            initialFrame: enteredNewZone
                ? WindowSnapPreviewAnimation.initialFrame(for: plan, screens: snapScreens)
                : nil
        )
    }

    private func hideSnapPreview() {
        guard lastPreviewPlan != nil || snapPreview.isVisible else {
            snapPreview.hide()
            return
        }
        lastPreviewPlan = nil
        snapPreview.hide()
    }

    /// 把 MenuTools 刚套用过的窗口拖出来时，恢复吸附前的尺寸。
    ///
    /// 只在指针移动超过阈值后触发一次：单纯点击标题栏不应该改变窗口大小。
    private func prepareUnsnapRestoreIfNeeded(at point: CGPoint) {
        guard configuration.restoreSizeWhenDraggingOut,
              !unsnapHandledForCurrentDrag,
              let start = mouseDownLocation,
              hypot(point.x - start.x, point.y - start.y) > 8 else { return }
        unsnapHandledForCurrentDrag = true

        guard let window = dragWindow,
              let processIdentifier = dragWindowPID,
              let current = dragWindowFrameAtMouseDown else { return }
        let key = bundleIdentifier(for: processIdentifier)
        guard let applied = lastAppliedFrames[key], framesMatch(current, applied),
              let previous = frameMemory.previousFrame(for: key),
              let visible = screen(for: window),
              let target = WindowUnsnapCalculator.restoredFrame(
                  current: current,
                  previous: previous,
                  cursor: point,
                  visibleFrame: visible
              ) else { return }

        SnapDebugLog.log("unsnap: restore size from \(NSStringFromRect(current)) to \(NSStringFromRect(target))")
        try? setFrame(target, of: window)
        lastAppliedFrames[key] = target
    }

    /// 位置与尺寸是否与记录一致（AX 有取整误差）。
    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 4
            && abs(lhs.minY - rhs.minY) < 4
            && abs(lhs.width - rhs.width) < 4
            && abs(lhs.height - rhs.height) < 4
    }

    private func recordAppliedFrame(_ frame: CGRect, processIdentifier: pid_t) {
        lastAppliedFrames[bundleIdentifier(for: processIdentifier)] = frame
    }

    /// 吸附松手：按鼠标松手位置所在的显示器计算落点，而不是窗口当前所在的显示器。
    private func snapWindow(at point: CGPoint) {
        guard AXIsProcessTrusted(),
              let window = dragWindow,
              let processIdentifier = dragWindowPID,
              let plan = WindowSnapPreviewPlanner.plan(
                for: point,
                windowFrame: dragWindowFrame,
                screens: snapScreens,
                options: configuration.options,
                detailedSnapAreas: configuration.detailedSnapAreas,
                snapAreaMapping: configuration.snapAreaMapping
              ) else {
            SnapDebugLog.log("snap on mouseUp: skipped (window=\(dragWindow != nil) pid=\(dragWindowPID != nil) point=\(NSStringFromPoint(NSEvent.mouseLocation)) windowFrame=\(dragWindowFrame.map(NSStringFromRect) ?? "nil"))")
            return
        }
        SnapDebugLog.log("snap on mouseUp: apply layout=\(plan.layout.rawValue)")
        rememberFrameBeforeLayout(of: window, processIdentifier: processIdentifier)
        try? setFrame(plan.frame, of: window)
        recordAppliedFrame(plan.frame, processIdentifier: processIdentifier)
    }

    /// 被拖动窗口当前的位置（AX 在拖动过程中可能仍报旧值，松手时才是最新的）。
    private var dragWindowFrame: CGRect? {
        guard let dragWindow else { return nil }
        return try? cocoaFrame(of: dragWindow)
    }

    private var snapScreens: [WindowSnapScreen] {
        NSScreen.screens.map { WindowSnapScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    /// 用命中测试取「鼠标下的窗口」。
    ///
    /// 不能用“前台应用的焦点窗口”：拖动后台窗口、或同一个应用的其他窗口时，焦点窗口并不是
    /// 被拖动的那个，会导致整条吸附链路直接失效。命中测试还会在拖动过程中重试。
    private func captureDragWindow(at point: CGPoint) {
        guard dragWindow == nil, dragWindowLookupAttempts < 20 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if lastDragWindowLookup > 0, now - lastDragWindowLookup < 0.1 { return }
        lastDragWindowLookup = now
        dragWindowLookupAttempts += 1

        guard let window = windowUnderCursor(at: point) else {
            SnapDebugLog.log("hit test attempt \(dragWindowLookupAttempts): no window found")
            return
        }
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(window, &processIdentifier) == .success else { return }
        guard !isExcluded(processIdentifier: processIdentifier) else {
            SnapDebugLog.log("hit window app excluded: pid=\(processIdentifier)")
            return
        }
        dragWindow = window
        dragWindowPID = processIdentifier
        dragWindowFrameAtMouseDown = try? cocoaFrame(of: window)
        dragStartedInWindowChrome = isTitleBarLocation(point, window: window)
    }

    /// 按下点是否落在窗口顶部的标题栏/工具栏区域。
    ///
    /// 这是区分「拖动窗口」和「在正文里划选内容」的可靠信号；用窗口位置是否变化来判断会误判，
    /// 因为应用往往直到拖拽结束才更新 AX 位置。
    private func isTitleBarLocation(_ point: CGPoint, window: AXUIElement) -> Bool {
        guard let frame = try? cocoaFrame(of: window) else { return false }
        return point.x >= frame.minX
            && point.x <= frame.maxX
            && point.y >= frame.maxY - Self.titleBarDragHeight
    }

    private static let titleBarDragHeight: CGFloat = 44

    /// AX 命中测试用的是左上原点坐标，这里把 Cocoa 坐标翻过去。
    private func windowUnderCursor(at point: CGPoint) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let axPoint = CGPoint(x: point.x, y: desktopTop - point.y)
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(axPoint.x),
            Float(axPoint.y),
            &element
        ) == .success, let element else { return nil }
        return windowElement(from: element)
    }

    /// 命中到的通常是标题栏里的按钮或内容区，需要向上找到窗口元素。
    private func windowElement(from element: AXUIElement) -> AXUIElement? {
        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
           let windowValue {
            return unsafeDowncast(windowValue, to: AXUIElement.self)
        }

        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 12 {
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role) == .success,
               (role as? String) == kAXWindowRole {
                return node
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent else { return nil }
            current = unsafeDowncast(parent, to: AXUIElement.self)
            depth += 1
        }
        return nil
    }

    private func externalProcessIdentifier() throws -> pid_t {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let processIdentifier = WindowTargetResolver.preferredProcessIdentifier(
            frontmost: frontmostProcessIdentifier,
            remembered: lastExternalApplicationPID,
            own: ownProcessIdentifier
        ) else { throw WindowManagementError.noFocusedWindow }
        lastExternalApplicationPID = processIdentifier
        return processIdentifier
    }

    private func focusedWindow(of processIdentifier: pid_t) throws -> AXUIElement {
        lastExternalApplicationPID = processIdentifier
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success, let value else {
            throw WindowManagementError.noFocusedWindow
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func isExcluded(processIdentifier: pid_t) -> Bool {
        guard let bundleIdentifier = NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier else {
            return false
        }
        return configuration.excludedBundleIdentifiers.contains(bundleIdentifier)
    }

    private func windowElements(of application: AXUIElement) throws -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let value,
              let windows = value as? [AXUIElement] else {
            throw WindowManagementError.noFocusedWindow
        }
        return windows.filter { window in
            var role: CFTypeRef?
            var minimized: CFTypeRef?
            let hasRole = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success
            let isWindow = (role as? String) == kAXWindowRole
            _ = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            let isMinimized = (minimized as? NSNumber)?.boolValue ?? false
            return hasRole && isWindow && !isMinimized
        }
    }

    private func accessibilityFrame(of window: AXUIElement) throws -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue else {
            throw WindowManagementError.operationFailed(L("window.error.readFrame"))
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            throw WindowManagementError.operationFailed(L("window.error.readFrame"))
        }
        return CGRect(origin: origin, size: size)
    }

    private func cocoaFrame(of window: AXUIElement) throws -> CGRect {
        WindowCoordinateConverter.fromAccessibility(
            try accessibilityFrame(of: window),
            desktopTop: desktopTop
        )
    }

    private func setFrame(_ frame: CGRect, of window: AXUIElement) throws {
        var origin = WindowCoordinateConverter.toAccessibility(
            frame,
            desktopTop: desktopTop
        ).origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin),
              let axSize = AXValueCreate(.cgSize, &size),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success,
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSize) == .success else {
            throw WindowManagementError.operationFailed(L("window.error.writeFrame"))
        }
    }

    private func currentSize(of window: AXUIElement) -> CGSize {
        (try? accessibilityFrame(of: window).size) ?? CGSize(width: 900, height: 650)
    }

    private func screen(for window: AXUIElement) -> CGRect? {
        guard let frame = try? cocoaFrame(of: window) else { return NSScreen.main?.visibleFrame }
        return NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame
    }

    private func move(window: AXUIElement, displayOffset: Int) throws {
        guard let current = screen(for: window),
              let currentIndex = NSScreen.screens.firstIndex(where: { $0.visibleFrame == current }),
              !NSScreen.screens.isEmpty else {
            throw WindowManagementError.operationFailed(L("window.error.noScreen"))
        }
        let screenCount = NSScreen.screens.count
        let nextIndex = (currentIndex + displayOffset % screenCount + screenCount) % screenCount
        let nextScreen = NSScreen.screens[nextIndex].visibleFrame
        let oldFrame = try cocoaFrame(of: window)
        let target = CGRect(
            x: nextScreen.midX - oldFrame.width / 2,
            y: nextScreen.midY - oldFrame.height / 2,
            width: oldFrame.width,
            height: oldFrame.height
        )
        try setFrame(target, of: window)
    }

    private func toggleFullscreen(window: AXUIElement) throws {
        let attribute = "AXFullScreen" as CFString
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute, &value) == .success,
              let current = value as? NSNumber else {
            throw WindowManagementError.operationFailed(L("window.error.fullscreen"))
        }
        let target = NSNumber(value: !current.boolValue)
        guard AXUIElementSetAttributeValue(window, attribute, target) == .success else {
            throw WindowManagementError.operationFailed(L("window.error.fullscreen"))
        }
    }

    private func nudge(window: AXUIElement, dx: CGFloat, dy: CGFloat) throws {
        let current = try cocoaFrame(of: window)
        guard let screen = screen(for: window) else {
            throw WindowManagementError.operationFailed(L("window.error.noScreen"))
        }
        let targetOrigin = CGPoint(
            x: min(max(current.minX + dx, screen.minX), screen.maxX - current.width),
            y: min(max(current.minY + dy, screen.minY), screen.maxY - current.height)
        )
        try setFrame(CGRect(origin: targetOrigin, size: current.size), of: window)
    }

    private func postDesktopShortcut(keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = .maskControl
        keyUp.flags = .maskControl
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// 方向键挪动距离；按住 Option 时精调。
    private var nudgeDistance: CGFloat {
        WindowNudge.offset(
            step: configuration.options.nudgeStep,
            isFine: NSEvent.modifierFlags.contains(.option)
        )
    }

    /// 连按同一快捷键时，在同一分数族内循环到下一个布局。
    private func resolvedLayout(_ layout: WindowLayout, targetKey: String) -> WindowLayout {
        guard configuration.cycleLayouts else {
            cycleState.reset()
            return layout
        }
        return cycleState.nextLayout(requested: layout, targetKey: targetKey)
    }

    /// 循环布局与跨显示器遍历共用的目标标识：应用 + 窗口标题。
    private func cycleTargetKey(processIdentifier: pid_t, window: AXUIElement) -> String {
        "\(bundleIdentifier(for: processIdentifier))|\(windowTitle(of: window) ?? "")"
    }

    /// 应用布局前记录当前帧，让「还原」不需要用户先手动记住尺寸。
    private func rememberFrameBeforeLayout(of window: AXUIElement, processIdentifier: pid_t) {
        guard let frame = try? cocoaFrame(of: window) else { return }
        frameMemory.rememberPreviousFrame(frame, for: bundleIdentifier(for: processIdentifier))
    }

    private func bundleIdentifier(for processIdentifier: pid_t) -> String {
        NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier ?? "pid-\(processIdentifier)"
    }

    private func windowTitle(of window: AXUIElement) -> String? {
        stringAttribute(kAXTitleAttribute, of: window)
    }

    /// 焦点窗口是不是该应用的主窗口。
    private func isMainWindow(_ window: AXUIElement, of processIdentifier: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMainWindowAttribute as CFString, &value) == .success,
              let value else { return true }
        return CFEqual(window, unsafeDowncast(value, to: AXUIElement.self))
    }

    private func stringAttribute(_ name: String, of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func arrangementCandidate(of window: AXUIElement) -> WindowArrangementCandidate {
        WindowArrangementCandidate(
            frame: (try? cocoaFrame(of: window)) ?? .zero,
            isFullScreen: isFullScreen(window),
            isMinimized: false
        )
    }

    private func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success,
              let number = value as? NSNumber else { return false }
        return number.boolValue
    }

    private var desktopTop: CGFloat {
        NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.maxY ?? 0
    }
}
