import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

enum ScreenshotRegionSelectionError: LocalizedError {
    case cancelled
    case unavailable

    var errorDescription: String? {
        switch self {
        case .cancelled: return L("screenshot.error.selectionCancelled")
        case .unavailable: return L("screenshot.error.selectionUnavailable")
        }
    }
}

/// 将 AppKit 左下角坐标转换为 screencapture 使用的屏幕坐标。
enum ScreenshotRegionCoordinateConverter {
    static func screencaptureRect(from appKitRect: CGRect, in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: appKitRect.minX - screenFrame.minX,
            y: screenFrame.maxY - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }
}

enum ScreenshotSelectionGeometry {
    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        ).standardized
    }

    static func sizeLabel(for rect: CGRect) -> String {
        "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
    }
}

/// 同一个选区层返回的结果。窗口模式只返回 WindowServer ID，截图时再走
/// ScreenCaptureKit/`screencapture -l`，避免把 overlay 自身截进去。
enum ScreenshotAreaSelectionResult: Equatable, Sendable {
    case region(CGRect)
    case window(CGWindowID)
}

enum ScreenshotSelectionInteractionEvent {
    case mouseMoved(CGPoint)
    case mouseDown(CGPoint)
    case mouseDragged(CGPoint)
    case mouseUp(CGPoint)
    case toggleWindowMode
    case cancel
}

enum ScreenshotSelectionInteractionResult: Equatable {
    case none
    case completed(ScreenshotAreaSelectionResult)
    case cancelled
}

/// 将选区手势与 AppKit 窗口隔离，保证拖选、窗口模式和取消都可以用纯逻辑测试。
struct ScreenshotSelectionInteractionModel {
    let allowsWindowMode: Bool
    let windowTargets: [ScreenshotWindowTarget]
    private(set) var isWindowMode = false
    private(set) var startPoint: CGPoint?
    private(set) var selection: CGRect = .zero
    private(set) var highlightedWindow: ScreenshotWindowTarget?

    init(allowsWindowMode: Bool, windowTargets: [ScreenshotWindowTarget]) {
        self.allowsWindowMode = allowsWindowMode
        self.windowTargets = windowTargets
    }

    mutating func handle(_ event: ScreenshotSelectionInteractionEvent) -> ScreenshotSelectionInteractionResult {
        switch event {
        case let .mouseMoved(point):
            highlightedWindow = isWindowMode
                ? ScreenshotWindowQuery.hitTest(point, targets: windowTargets)
                : nil
            return .none
        case let .mouseDown(point):
            if isWindowMode {
                guard let highlightedWindow else { return .none }
                return .completed(.window(highlightedWindow.id))
            }
            startPoint = point
            selection = .zero
            return .none
        case let .mouseDragged(point):
            guard let startPoint else { return .none }
            selection = ScreenshotSelectionGeometry.rect(from: startPoint, to: point)
            return .none
        case let .mouseUp(point):
            guard let startPoint else { return .none }
            let result = ScreenshotSelectionGeometry.rect(from: startPoint, to: point)
            self.startPoint = nil
            selection = result
            guard result.width >= 8, result.height >= 8 else {
                return .cancelled
            }
            return .completed(.region(result))
        case .toggleWindowMode:
            guard allowsWindowMode else { return .none }
            isWindowMode.toggle()
            startPoint = nil
            selection = .zero
            highlightedWindow = nil
            return .none
        case .cancel:
            return .cancelled
        }
    }
}

private typealias RegionSelectionEvent = ScreenshotSelectionInteractionEvent

/// 多显示器选区层。每块显示器使用一个独立的全空间窗口，拖动状态由选择器
/// 统一维护，因此跨屏拖动不会经过一个跨显示器的大窗口，也不会丢失显示器
/// 之间的坐标原点。
@MainActor
final class ScreenshotRegionSelector {
    static let shared = ScreenshotRegionSelector()

    private var windows: [RegionSelectionWindow] = []
    private var continuation: CheckedContinuation<ScreenshotAreaSelectionResult, Error>?
    private var interactionModel: ScreenshotSelectionInteractionModel?
    private var recoveryObservers: [NSObjectProtocol] = []
    private var watchdogTask: Task<Void, Never>?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    func select() async throws -> CGRect {
        let result = try await selectArea(allowsWindowMode: false)
        guard case let .region(rect) = result else {
            throw ScreenshotRegionSelectionError.cancelled
        }
        return rect
    }

    func selectArea() async throws -> ScreenshotAreaSelectionResult {
        try await selectArea(allowsWindowMode: true)
    }

    private func selectArea(allowsWindowMode: Bool) async throws -> ScreenshotAreaSelectionResult {
        guard continuation == nil else { throw ScreenshotRegionSelectionError.unavailable }
        guard !NSScreen.screens.isEmpty else {
            throw ScreenshotRegionSelectionError.unavailable
        }

        let targets = allowsWindowMode ? ScreenshotWindowQuery.candidates() : []
        self.interactionModel = ScreenshotSelectionInteractionModel(
            allowsWindowMode: allowsWindowMode,
            windowTargets: targets
        )

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.windows = NSScreen.screens.map { screen in
                    let selectionWindow = RegionSelectionWindow(frame: screen.frame)
                    selectionWindow.onEvent = { [weak self] event in
                        self?.handle(event)
                    }
                    selectionWindow.orderFrontRegardless()
                    return selectionWindow
                }
                self.windows.forEach {
                    $0.updateMode(
                        isWindowMode: false,
                        frame: .zero,
                        title: "",
                        allowsWindowMode: allowsWindowMode
                    )
                }
                self.installCancellationKeyMonitors()
                self.installRecoveryWatchdog()
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

    private func handle(_ event: RegionSelectionEvent) {
        if case let .mouseMoved(point) = event {
            windows.forEach { $0.updatePointer(point) }
        }
        guard var model = interactionModel else { return }
        var result = model.handle(event)
        if case .toggleWindowMode = event, model.isWindowMode {
            result = model.handle(.mouseMoved(NSEvent.mouseLocation))
        }
        interactionModel = model

        switch event {
        case .mouseMoved, .toggleWindowMode:
            let title: String
            if model.isWindowMode {
                title = model.highlightedWindow?.displayName ?? L("screenshot.windowSelection.move")
            } else {
                title = L("screenshot.region.move")
            }
            windows.forEach {
                $0.updateMode(
                    isWindowMode: model.isWindowMode,
                    frame: model.highlightedWindow?.frame ?? .zero,
                    title: title,
                    allowsWindowMode: model.allowsWindowMode
                )
            }
        case .mouseDown, .mouseDragged, .mouseUp:
            windows.forEach { $0.updateSelection(model.selection) }
        case .cancel:
            break
        }

        switch result {
        case .none:
            break
        case let .completed(selection):
            finish(.success(selection))
        case .cancelled:
            finish(.failure(ScreenshotRegionSelectionError.cancelled))
        }
    }

    private func finish(_ result: Result<ScreenshotAreaSelectionResult, Error>) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        interactionModel = nil
        removeCancellationKeyMonitors()
        recoveryObservers.forEach(NotificationCenter.default.removeObserver)
        recoveryObservers.removeAll()
        watchdogTask?.cancel()
        watchdogTask = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    /// 菜单栏应用的选区窗口可能无法成为当前系统前台应用；全局监听保证 Esc
    /// 仍能取消选区，本地监听则让已经激活的选区窗口立即吞掉该按键。
    private func installCancellationKeyMonitors() {
        removeCancellationKeyMonitors()
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                self?.handle(.cancel)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor [weak self] in
                self?.handle(.cancel)
            }
            return nil
        }
    }

    private func removeCancellationKeyMonitors() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        globalKeyMonitor = nil
        localKeyMonitor = nil
    }

    private func installRecoveryWatchdog() {
        recoveryObservers.forEach(NotificationCenter.default.removeObserver)
        recoveryObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.recoverOverlayPresentation() }
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.recoverOverlayPresentation() }
            }
        ]

        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.continuation != nil else { return }
                self.recoverOverlayPresentation()
            }
        }
    }

    private func recoverOverlayPresentation() {
        guard continuation != nil else { return }
        for window in windows {
            if !window.isVisible || window.occlusionState.contains(.visible) == false {
                window.orderFrontRegardless()
            }
            window.contentView?.needsDisplay = true
        }
        windows.first?.makeKey()
    }
}

@MainActor
private final class RegionSelectionWindow: NSPanel {
    var onEvent: ((RegionSelectionEvent) -> Void)?

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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        sharingType = .none
        contentView = RegionSelectionView(
            frame: CGRect(origin: .zero, size: frame.size),
            screenFrame: frame
        ) { [weak self] event in
            self?.onEvent?(event)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func updateSelection(_ selection: CGRect) {
        (contentView as? RegionSelectionView)?.selectionGlobal = selection
    }

    func updatePointer(_ point: CGPoint) {
        (contentView as? RegionSelectionView)?.pointerGlobal = point
    }

    func updateMode(
        isWindowMode: Bool,
        frame: CGRect,
        title: String,
        allowsWindowMode: Bool = true
    ) {
        (contentView as? RegionSelectionView)?.isWindowMode = isWindowMode
        (contentView as? RegionSelectionView)?.windowFrame = frame
        (contentView as? RegionSelectionView)?.windowTitle = title
        (contentView as? RegionSelectionView)?.windowModeToggleEnabled = allowsWindowMode
    }
}

@MainActor
private final class RegionSelectionView: NSView {
    var selectionGlobal: CGRect = .zero {
        didSet { needsDisplay = true }
    }

    var pointerGlobal: CGPoint? {
        didSet { needsDisplay = true }
    }

    var isWindowMode = false {
        didSet { needsDisplay = true }
    }

    var windowFrame: CGRect = .zero {
        didSet { needsDisplay = true }
    }

    var windowTitle = "" {
        didSet { needsDisplay = true }
    }

    var windowModeToggleEnabled = false {
        didSet { needsDisplay = true }
    }

    private let screenFrame: CGRect
    private let onEvent: (RegionSelectionEvent) -> Void
    private var loupeImage: CGImage?
    private var loupeTask: Task<Void, Never>?

    init(frame: CGRect, screenFrame: CGRect, onEvent: @escaping (RegionSelectionEvent) -> Void) {
        self.screenFrame = screenFrame
        self.onEvent = onEvent
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        dirtyRect.fill()

        if isWindowMode {
            drawWindowHighlight()
        } else if windowModeToggleEnabled, selectionGlobal.isEmpty {
            drawModeHint()
        }

        if !isWindowMode, let localSelection, localSelection.width > 0, localSelection.height > 0 {
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.setBlendMode(.clear)
                context.fill(localSelection)
                context.restoreGState()
            }

            NSColor.systemBlue.withAlphaComponent(0.12).setFill()
            localSelection.fill()
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: localSelection)
            path.lineWidth = 2
            path.stroke()

            let label = ScreenshotSelectionGeometry.sizeLabel(for: selectionGlobal)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let textSize = (label as NSString).size(withAttributes: attributes)
            let badge = CGRect(
                x: max(8, min(localSelection.midX - textSize.width / 2 - 8, bounds.maxX - textSize.width - 24)),
                y: max(8, localSelection.minY - textSize.height - 14),
                width: textSize.width + 16,
                height: textSize.height + 8
            )
            NSColor.systemBlue.withAlphaComponent(0.94).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
            (label as NSString).draw(
                at: CGPoint(x: badge.minX + 8, y: badge.minY + 4),
                withAttributes: attributes
            )
        }

        guard let pointerGlobal,
              screenFrame.contains(pointerGlobal) else { return }

        let coordinate = "\(Int(pointerGlobal.x.rounded())), \(Int(pointerGlobal.y.rounded()))"
        let coordinateAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let coordinateSize = (coordinate as NSString).size(withAttributes: coordinateAttributes)
        let coordinateBadge = CGRect(
            x: min(max(8, pointerGlobal.x - screenFrame.minX + 8), bounds.maxX - coordinateSize.width - 16),
            y: max(8, pointerGlobal.y - screenFrame.minY - coordinateSize.height - 14),
            width: coordinateSize.width + 16,
            height: coordinateSize.height + 8
        )
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: coordinateBadge, xRadius: 5, yRadius: 5).fill()
        (coordinate as NSString).draw(
            at: CGPoint(x: coordinateBadge.minX + 8, y: coordinateBadge.minY + 4),
            withAttributes: coordinateAttributes
        )

        drawLoupe(at: pointerGlobal)
    }

    override func mouseDown(with event: NSEvent) {
        onEvent(.mouseDown(globalPoint(for: event)))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = globalPoint(for: event)
        onEvent(.mouseMoved(point))
        requestLoupeImage(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        onEvent(.mouseDragged(globalPoint(for: event)))
    }

    override func mouseUp(with event: NSEvent) {
        onEvent(.mouseUp(globalPoint(for: event)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEvent(.cancel)
        } else if event.keyCode == 0 {
            onEvent(.toggleWindowMode)
        } else {
            super.keyDown(with: event)
        }
    }

    private var localSelection: CGRect? {
        guard !selectionGlobal.isEmpty else { return nil }
        return selectionGlobal
            .intersection(screenFrame)
            .offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    private func drawWindowHighlight() {
        guard !windowFrame.isEmpty else {
            drawModeHint()
            return
        }
        let local = windowFrame.intersection(screenFrame)
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

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let title = windowTitle.isEmpty ? L("screenshot.windowSelection.move") : windowTitle
        let titleSize = (title as NSString).size(withAttributes: attributes)
        let badge = CGRect(
            x: max(8, min(local.minX, bounds.maxX - titleSize.width - 20)),
            y: min(bounds.maxY - titleSize.height - 18, local.maxY + 8),
            width: titleSize.width + 16,
            height: titleSize.height + 8
        )
        NSColor.systemBlue.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        (title as NSString).draw(
            at: CGPoint(x: badge.minX + 8, y: badge.minY + 4),
            withAttributes: attributes
        )
    }

    private func drawModeHint() {
        let text = L("screenshot.region.modeHint")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let badge = CGRect(
            x: max(12, (bounds.width - size.width - 20) / 2),
            y: bounds.height - size.height - 28,
            width: size.width + 20,
            height: size.height + 10
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(
            at: CGPoint(x: badge.minX + 10, y: badge.minY + 5),
            withAttributes: attributes
        )
    }

    private func drawLoupe(at point: CGPoint) {
        guard let image = loupeImage else { return }

        let loupeSize: CGFloat = 116
        let center = CGPoint(
            x: min(max(loupeSize / 2 + 8, point.x - screenFrame.minX + loupeSize / 2 + 18), bounds.maxX - loupeSize / 2 - 8),
            y: min(max(loupeSize / 2 + 8, point.y - screenFrame.minY + loupeSize / 2 + 18), bounds.maxY - loupeSize / 2 - 8)
        )
        let loupeRect = CGRect(
            x: center.x - loupeSize / 2,
            y: center.y - loupeSize / 2,
            width: loupeSize,
            height: loupeSize
        )
        NSGraphicsContext.current?.cgContext.saveGState()
        NSBezierPath(ovalIn: loupeRect).addClip()
        NSImage(cgImage: image, size: NSSize(width: loupeSize, height: loupeSize))
            .draw(in: loupeRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.cgContext.restoreGState()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(ovalIn: loupeRect)
        border.lineWidth = 2
        border.stroke()
        NSColor.systemRed.setStroke()
        let crosshair = NSBezierPath()
        crosshair.move(to: CGPoint(x: center.x - 8, y: center.y))
        crosshair.line(to: CGPoint(x: center.x + 8, y: center.y))
        crosshair.move(to: CGPoint(x: center.x, y: center.y - 8))
        crosshair.line(to: CGPoint(x: center.x, y: center.y + 8))
        crosshair.lineWidth = 1
        crosshair.stroke()
    }

    private func requestLoupeImage(at point: CGPoint) {
        loupeTask?.cancel()
        loupeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard let self, !Task.isCancelled,
                  let number = NSScreen.screens.first(where: { $0.frame == self.screenFrame })?
                    .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { return }
                let screen = NSScreen.screens.first(where: { $0.frame == self.screenFrame })
                let scale = max(screen?.backingScaleFactor ?? 1, 1)
                let sampleSize: CGFloat = 72
                let localPoint = CGPoint(
                    x: point.x - self.screenFrame.minX,
                    y: self.screenFrame.maxY - point.y
                )
                let sourceRect = CGRect(
                    x: max(0, localPoint.x - sampleSize / 2),
                    y: max(0, localPoint.y - sampleSize / 2),
                    width: sampleSize,
                    height: sampleSize
                )
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = sourceRect
                configuration.width = max(1, Int(sampleSize * scale))
                configuration.height = max(1, Int(sampleSize * scale))
                configuration.showsCursor = false
                if #available(macOS 14.2, *) {
                    configuration.captureResolution = .best
                }
                let excluded = Bundle.main.bundleIdentifier.map { bundleID in
                    content.applications.filter { $0.bundleIdentifier == bundleID }
                } ?? []
                let filter = excluded.isEmpty
                    ? SCContentFilter(display: display, excludingWindows: [])
                    : SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                self.loupeImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                self.needsDisplay = true
            } catch {
                // 选区层不能因为截屏权限或系统采集延迟中断，放大镜静默隐藏即可。
            }
        }
    }
}

/// 选区确认后的高亮层。窗口不接收鼠标事件，因此用户仍可以直接滚动
/// 目标应用；ScreenCaptureKit 会排除 MenuTools 自身窗口，不会把高亮框录入截图。
@MainActor
final class ScreenshotRangeHighlight {
    static let shared = ScreenshotRangeHighlight()

    private var window: RegionHighlightWindow?
    private var controlWindow: LongScreenshotControlWindow?
    private var previewWindow: LongScreenshotPreviewWindow?

    func show(
        rect: CGRect,
        message: String,
        finishAction: (() -> Void)? = nil
    ) {
        let highlightWindow: RegionHighlightWindow
        if let window {
            highlightWindow = window
            highlightWindow.setFrame(rect, display: true)
        } else {
            highlightWindow = RegionHighlightWindow(frame: rect)
            window = highlightWindow
        }
        highlightWindow.message = message
        highlightWindow.orderFrontRegardless()

        if let finishAction {
            let controlRect = LongScreenshotControlWindow.rect(near: rect)
            if let controlWindow {
                controlWindow.setFrame(controlRect, display: true)
                controlWindow.onFinish = finishAction
            } else {
                controlWindow = LongScreenshotControlWindow(
                    frame: controlRect,
                    onFinish: finishAction
                )
            }
            controlWindow?.orderFrontRegardless()
            let previewRect = LongScreenshotPreviewWindow.rect(near: rect)
            if let previewWindow {
                previewWindow.setFrame(previewRect, display: true)
            } else {
                previewWindow = LongScreenshotPreviewWindow(frame: previewRect)
            }
            previewWindow?.orderFrontRegardless()
        } else {
            controlWindow?.orderOut(nil)
            previewWindow?.orderOut(nil)
        }
    }

    func hide() {
        window?.orderOut(nil)
        controlWindow?.orderOut(nil)
        previewWindow?.orderOut(nil)
    }

    func clearMessage() {
        window?.message = ""
    }

    func updateLongPreview(_ image: CGImage, frameCount: Int) {
        previewWindow?.update(image: image, frameCount: frameCount)
    }
}

@MainActor
private final class RegionHighlightWindow: NSPanel {
    var message: String = "" {
        didSet { (contentView as? RegionHighlightView)?.message = message }
    }

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
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = RegionHighlightView(frame: CGRect(origin: .zero, size: frame.size))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 长截图期间显示在选区边缘的完成按钮。按钮位于独立窗口中，选区本身仍
/// 忽略鼠标事件，因此不会阻止用户在目标应用里滚动；ScreenCaptureKit 只
/// 采集目标应用进程，也不会把这个 MenuTools 控件写进长图。
@MainActor
private final class LongScreenshotControlWindow: NSPanel {
    var onFinish: (() -> Void)? {
        didSet { (contentView as? LongScreenshotControlView)?.onFinish = onFinish }
    }

    init(frame: CGRect, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        contentView = LongScreenshotControlView(
            frame: CGRect(origin: .zero, size: frame.size),
            onFinish: onFinish
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func rect(near selection: CGRect) -> CGRect {
        let size = CGSize(width: 168, height: 34)
        let screenFrame = NSScreen.screens.first(where: { $0.frame.intersects(selection) })?.frame
            ?? NSScreen.main?.frame
            ?? selection
        let horizontalInset: CGFloat = 8
        let x = min(
            max(screenFrame.minX + horizontalInset, selection.maxX - size.width),
            screenFrame.maxX - size.width - horizontalInset
        )
        let belowY = selection.minY - size.height - 8
        let y = belowY >= screenFrame.minY + horizontalInset
            ? belowY
            : min(selection.maxY + 8, screenFrame.maxY - size.height - horizontalInset)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

@MainActor
private final class LongScreenshotPreviewWindow: NSPanel {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = LongScreenshotPreviewView(frame: CGRect(origin: .zero, size: frame.size))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(image: CGImage, frameCount: Int) {
        (contentView as? LongScreenshotPreviewView)?.update(image: image, frameCount: frameCount)
    }

    static func rect(near selection: CGRect) -> CGRect {
        let size = CGSize(width: 240, height: 172)
        let screenFrame = NSScreen.screens.first(where: { $0.frame.intersects(selection) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? selection
        let rightX = selection.maxX + 12
        let leftX = selection.minX - size.width - 12
        let x = rightX + size.width <= screenFrame.maxX - 8
            ? rightX
            : max(screenFrame.minX + 8, leftX)
        let topY = selection.maxY - size.height
        let y = max(screenFrame.minY + 8, min(topY, screenFrame.maxY - size.height - 8))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

@MainActor
private final class LongScreenshotPreviewView: NSView {
    private var image: NSImage?
    private var frameCount = 0

    func update(image: CGImage, frameCount: Int) {
        self.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        self.frameCount = frameCount
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        let imageRect = bounds.insetBy(dx: 10, dy: 30)
        image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)

        let label = L("screenshot.long.preview", frameCount)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        (label as NSString).draw(
            at: CGPoint(x: 12, y: 10),
            withAttributes: attributes
        )
    }
}

@MainActor
private final class LongScreenshotControlView: NSView {
    var onFinish: (() -> Void)?

    private var button: NSButton?

    init(frame: CGRect, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init(frame: frame)
        let button = NSButton(
            title: L("screenshot.long.finish"),
            target: self,
            action: #selector(finishButtonPressed(_:))
        )
        self.button = button
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.systemBlue.cgColor
        button.layer?.cornerRadius = 8
        button.frame = bounds
        button.autoresizingMask = [.width, .height]
        addSubview(button)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func finishButtonPressed(_ sender: NSButton) {
        onFinish?()
    }
}

@MainActor
private final class RegionHighlightView: NSView {
    var message: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.withAlphaComponent(0.08).setFill()
        dirtyRect.fill()

        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 5,
            yRadius: 5
        )
        border.lineWidth = 3
        border.stroke()

        guard !message.isEmpty, bounds.width >= 120, bounds.height >= 36 else { return }
        let badge = NSRect(x: 10, y: bounds.height - 32, width: min(bounds.width - 20, 220), height: 22)
        NSColor.systemBlue.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        (message as NSString).draw(
            in: badge.insetBy(dx: 8, dy: 3),
            withAttributes: attributes
        )
    }
}
