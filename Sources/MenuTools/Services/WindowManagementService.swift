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

    var id: String { rawValue }
    var titleKey: String { "window.\(rawValue)" }
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
        }
    }
}

enum WindowLayoutCalculator {
    static func frame(
        for layout: WindowLayout,
        in screen: CGRect,
        preferredSize: CGSize = CGSize(width: 900, height: 650)
    ) -> CGRect {
        let gap: CGFloat = 8
        let safe = screen.insetBy(dx: gap, dy: gap)
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
        }
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
    case accessibilityPermission
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFocusedWindow: return L("window.error.noWindow")
        case .accessibilityPermission: return L("window.error.permission")
        case let .operationFailed(message): return L("window.error.operation", message)
        }
    }
}

@MainActor
@Observable
final class WindowManagementService {
    static let shared = WindowManagementService()

    private(set) var lastSavedFrame: CGRect?
    private var lastExternalApplicationPID: pid_t?
    private var activationObserver: NSObjectProtocol?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let processIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor [weak self] in
                self?.rememberExternalApplication(processIdentifier: processIdentifier)
            }
        }
        rememberFrontmostExternalApplication()
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
        let window = try focusedWindow()
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
            try nudge(window: window, dx: -20, dy: 0)
            return
        case .moveRight:
            try nudge(window: window, dx: 20, dy: 0)
            return
        case .moveUp:
            try nudge(window: window, dx: 0, dy: 20)
            return
        case .moveDown:
            try nudge(window: window, dx: 0, dy: -20)
            return
        default:
            break
        }
        let screen = screen(for: window) ?? NSScreen.main?.visibleFrame ?? .zero
        guard !screen.isEmpty else { throw WindowManagementError.operationFailed(L("window.error.noScreen")) }
        let frame = WindowLayoutCalculator.frame(for: layout, in: screen, preferredSize: currentSize(of: window))
        try setFrame(frame, of: window)
    }

    func saveFocusedWindowFrame() throws {
        guard AXIsProcessTrusted() else { throw WindowManagementError.accessibilityPermission }
        let window = try focusedWindow()
        let frame = try cocoaFrame(of: window)
        lastSavedFrame = frame
        UserDefaults.standard.set(
            [Double(frame.origin.x), Double(frame.origin.y), Double(frame.size.width), Double(frame.size.height)],
            forKey: Self.savedFrameKey
        )
    }

    func restoreFocusedWindowFrame() throws {
        guard AXIsProcessTrusted() else { throw WindowManagementError.accessibilityPermission }
        let window = try focusedWindow()
        guard let values = UserDefaults.standard.array(forKey: Self.savedFrameKey) as? [Double], values.count == 4 else {
            throw WindowManagementError.operationFailed(L("window.error.noSavedFrame"))
        }
        try setFrame(
            CGRect(x: values[0], y: values[1], width: values[2], height: values[3]),
            of: window
        )
    }

    private static let savedFrameKey = "windowManagement.savedFrame"

    private func focusedWindow() throws -> AXUIElement {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let processIdentifier = WindowTargetResolver.preferredProcessIdentifier(
            frontmost: frontmostProcessIdentifier,
            remembered: lastExternalApplicationPID,
            own: ownProcessIdentifier
        )
        guard let processIdentifier else {
            throw WindowManagementError.noFocusedWindow
        }
        lastExternalApplicationPID = processIdentifier
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success, let value else {
            throw WindowManagementError.noFocusedWindow
        }
        return unsafeDowncast(value, to: AXUIElement.self)
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

    private var desktopTop: CGFloat {
        NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.maxY ?? 0
    }
}
