import ApplicationServices
import AppKit
import Foundation
import Observation

enum WindowLayout: String, CaseIterable, Identifiable, Sendable {
    case leftHalf
    case rightHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case centered
    case moveNextDisplay

    var id: String { rawValue }
    var titleKey: String { "window.\(rawValue)" }
    var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .centered: return "rectangle.center.inset.filled"
        case .moveNextDisplay: return "rectangle.on.rectangle.angled"
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
            return CGRect(x: safe.minX, y: safe.minY, width: safe.width / 2 - gap / 2, height: safe.height)
        case .rightHalf:
            return CGRect(x: safe.midX + gap / 2, y: safe.minY, width: safe.width / 2 - gap / 2, height: safe.height)
        case .topLeft:
            return quadrant(.topLeft, in: safe, gap: gap)
        case .topRight:
            return quadrant(.topRight, in: safe, gap: gap)
        case .bottomLeft:
            return quadrant(.bottomLeft, in: safe, gap: gap)
        case .bottomRight:
            return quadrant(.bottomRight, in: safe, gap: gap)
        case .centered:
            let size = CGSize(
                width: min(preferredSize.width, safe.width),
                height: min(preferredSize.height, safe.height)
            )
            return CGRect(
                x: safe.midX - size.width / 2,
                y: safe.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        case .moveNextDisplay:
            return screen
        }
    }

    private static func quadrant(_ quadrant: Quadrant, in screen: CGRect, gap: CGFloat) -> CGRect {
        let width = screen.width / 2 - gap / 2
        let height = screen.height / 2 - gap / 2
        let x = quadrant.isRight ? screen.midX + gap / 2 : screen.minX
        let y = quadrant.isTop ? screen.midY + gap / 2 : screen.minY
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private enum Quadrant {
        case topLeft, topRight, bottomLeft, bottomRight
        var isRight: Bool { self == .topRight || self == .bottomRight }
        var isTop: Bool { self == .topLeft || self == .topRight }
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
    private(set) var lastSavedFrame: CGRect?

    func apply(_ layout: WindowLayout) throws {
        guard AXIsProcessTrusted() else { throw WindowManagementError.accessibilityPermission }
        let window = try focusedWindow()
        if layout == .moveNextDisplay {
            try move(window: window)
            return
        }
        let screen = screen(for: window) ?? NSScreen.main?.visibleFrame ?? .zero
        guard !screen.isEmpty else { throw WindowManagementError.operationFailed(L("window.error.noScreen")) }
        let frame = WindowLayoutCalculator.frame(for: layout, in: screen, preferredSize: currentSize(of: window))
        try setFrame(frame, of: window)
    }

    func saveFocusedWindowFrame() throws {
        guard AXIsProcessTrusted() else { throw WindowManagementError.accessibilityPermission }
        let window = try focusedWindow()
        let frame = try frame(of: window)
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
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw WindowManagementError.noFocusedWindow
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success, let value else {
            throw WindowManagementError.noFocusedWindow
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func frame(of window: AXUIElement) throws -> CGRect {
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

    private func setFrame(_ frame: CGRect, of window: AXUIElement) throws {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin),
              let axSize = AXValueCreate(.cgSize, &size),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success,
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSize) == .success else {
            throw WindowManagementError.operationFailed(L("window.error.writeFrame"))
        }
    }

    private func currentSize(of window: AXUIElement) -> CGSize {
        (try? frame(of: window).size) ?? CGSize(width: 900, height: 650)
    }

    private func screen(for window: AXUIElement) -> CGRect? {
        guard let frame = try? frame(of: window) else { return NSScreen.main?.visibleFrame }
        return NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame
    }

    private func move(window: AXUIElement) throws {
        guard let current = screen(for: window),
              let currentIndex = NSScreen.screens.firstIndex(where: { $0.visibleFrame == current }),
              !NSScreen.screens.isEmpty else {
            throw WindowManagementError.operationFailed(L("window.error.noScreen"))
        }
        let nextScreen = NSScreen.screens[(currentIndex + 1) % NSScreen.screens.count].visibleFrame
        let oldFrame = try frame(of: window)
        let target = CGRect(
            x: nextScreen.midX - oldFrame.width / 2,
            y: nextScreen.midY - oldFrame.height / 2,
            width: oldFrame.width,
            height: oldFrame.height
        )
        try setFrame(target, of: window)
    }
}
