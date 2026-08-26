import AppKit
import CoreGraphics

struct ScreenshotWindowTarget: Equatable, Sendable {
    let id: CGWindowID
    let frame: CGRect
    let ownerName: String
    let title: String?

    var displayName: String {
        if let title, !title.isEmpty { return "\(ownerName) · \(title)" }
        return ownerName
    }
}

enum ScreenshotWindowSelectionError: LocalizedError {
    case cancelled
    case unavailable

    var errorDescription: String? {
        switch self {
        case .cancelled: return L("screenshot.windowSelection.cancelled")
        case .unavailable: return L("screenshot.windowSelection.unavailable")
        }
    }
}

/// 从 WindowServer 的前后顺序生成可悬停选择的窗口候选。
enum ScreenshotWindowQuery {
    static func candidates(excluding processID: pid_t = ProcessInfo.processInfo.processIdentifier) -> [ScreenshotWindowTarget] {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var seen = Set<CGWindowID>()
        return infos.compactMap { info in
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            let windowID = CGWindowID(number)
            guard seen.insert(windowID).inserted,
                  let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID != processID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let quartzFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  quartzFrame.width >= 80,
                  quartzFrame.height >= 60 else {
                return nil
            }

            guard let frame = appKitFrame(from: quartzFrame)?.integral else { return nil }
            guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return nil }
            return ScreenshotWindowTarget(
                id: windowID,
                frame: frame,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: (info[kCGWindowName as String] as? String)?.nilIfEmpty
            )
        }
    }

    static func hitTest(_ point: CGPoint, targets: [ScreenshotWindowTarget]) -> ScreenshotWindowTarget? {
        targets.first { $0.frame.contains(point) }
    }

    private static func appKitFrame(from quartzFrame: CGRect) -> CGRect? {
        let displays: [(screen: NSScreen, bounds: CGRect, area: CGFloat)] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            let intersection = bounds.intersection(quartzFrame)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                return nil
            }
            return (screen, bounds, intersection.width * intersection.height)
        }
        if let display = displays.max(by: { $0.area < $1.area }) {
            return ScreenshotWindowCoordinateConverter.appKitRect(
                from: quartzFrame,
                displayBounds: display.bounds,
                screenFrame: display.screen.frame
            )
        }

        // WindowServer 偶尔返回刚刚离屏的窗口，保留主屏回退以便用户仍可取消或重试。
        let mainScreenHeight = NSScreen.screens.first(where: { $0.screenshotDisplayID == CGMainDisplayID() })?.frame.height
            ?? CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: quartzFrame.minX,
            y: mainScreenHeight - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }
}

@MainActor
final class ScreenshotWindowSelector {
    static let shared = ScreenshotWindowSelector()

    private var windows: [ScreenshotWindowSelectionPanel] = []
    private var continuation: CheckedContinuation<CGWindowID, Error>?
    private var targets: [ScreenshotWindowTarget] = []
    private var highlightedTarget: ScreenshotWindowTarget?

    func select() async throws -> CGWindowID {
        guard continuation == nil else { throw ScreenshotWindowSelectionError.unavailable }
        targets = ScreenshotWindowQuery.candidates()
        guard !targets.isEmpty, !NSScreen.screens.isEmpty else {
            throw ScreenshotWindowSelectionError.unavailable
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.windows = NSScreen.screens.map { screen in
                    let panel = ScreenshotWindowSelectionPanel(frame: screen.frame)
                    panel.onEvent = { [weak self] event in self?.handle(event) }
                    panel.orderFrontRegardless()
                    return panel
                }
                self.windows.first?.makeKey()
                NSApp.activate(ignoringOtherApps: true)
                if Task.isCancelled {
                    self.finish(.failure(CancellationError()))
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.continuation != nil else { return }
                self.finish(.failure(CancellationError()))
            }
        })
    }

    private func handle(_ event: ScreenshotWindowSelectionEvent) {
        switch event {
        case let .moved(point):
            let target = ScreenshotWindowQuery.hitTest(point, targets: targets)
            highlightedTarget = target
            windows.forEach {
                $0.updateHighlight(frame: target?.frame ?? .zero, title: target?.displayName ?? "")
            }
        case .clicked:
            guard let highlightedTarget else {
                finish(.failure(ScreenshotWindowSelectionError.cancelled))
                return
            }
            finish(.success(highlightedTarget.id))
        case .cancel:
            finish(.failure(ScreenshotWindowSelectionError.cancelled))
        }
    }

    private func finish(_ result: Result<CGWindowID, Error>) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        targets.removeAll()
        highlightedTarget = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}

private enum ScreenshotWindowSelectionEvent {
    case moved(CGPoint)
    case clicked
    case cancel
}

@MainActor
private final class ScreenshotWindowSelectionPanel: NSPanel {
    var onEvent: ((ScreenshotWindowSelectionEvent) -> Void)?

    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        contentView = ScreenshotWindowSelectionView(
            frame: CGRect(origin: .zero, size: frame.size),
            screenFrame: frame
        ) { [weak self] event in
            self?.onEvent?(event)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func updateHighlight(frame: CGRect, title: String) {
        (contentView as? ScreenshotWindowSelectionView)?.highlightFrame = frame
        (contentView as? ScreenshotWindowSelectionView)?.highlightTitle = title
    }
}

@MainActor
private final class ScreenshotWindowSelectionView: NSView {
    var highlightFrame: CGRect = .zero {
        didSet { needsDisplay = true }
    }
    var highlightTitle: String = "" {
        didSet { needsDisplay = true }
    }

    private let screenFrame: CGRect
    private let onEvent: (ScreenshotWindowSelectionEvent) -> Void

    init(frame: CGRect, screenFrame: CGRect, onEvent: @escaping (ScreenshotWindowSelectionEvent) -> Void) {
        self.screenFrame = screenFrame
        self.onEvent = onEvent
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        dirtyRect.fill()
        guard !highlightFrame.isEmpty else { return }

        let local = highlightFrame.intersection(screenFrame)
            .offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        guard !local.isEmpty else { return }
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setBlendMode(.clear)
            context.fill(local)
            context.restoreGState()
        }
        NSColor.systemBlue.withAlphaComponent(0.1).setFill()
        local.fill()
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(roundedRect: local, xRadius: 5, yRadius: 5)
        border.lineWidth = 3
        border.stroke()

        guard !highlightTitle.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let titleSize = (highlightTitle as NSString).size(withAttributes: attributes)
        let badge = CGRect(
            x: max(8, min(local.minX, bounds.maxX - titleSize.width - 20)),
            y: min(bounds.maxY - titleSize.height - 18, local.maxY + 8),
            width: titleSize.width + 16,
            height: titleSize.height + 8
        )
        NSColor.systemBlue.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        (highlightTitle as NSString).draw(
            at: CGPoint(x: badge.minX + 8, y: badge.minY + 4),
            withAttributes: attributes
        )
    }

    override func mouseMoved(with event: NSEvent) {
        onEvent(.moved(globalPoint(for: event)))
    }

    override func mouseDown(with event: NSEvent) {
        onEvent(.clicked)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEvent(.cancel)
        } else {
            super.keyDown(with: event)
        }
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
