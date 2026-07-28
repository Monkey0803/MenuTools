import AppKit
import CoreGraphics

/// 平滑滚动引擎：用 CGEventTap 拦截鼠标滚轮，插值为平滑的像素级滚动。
/// 仅处理鼠标滚轮（非连续事件），触控板/合成事件原样放行。需“辅助功能”权限。
/// 借鉴 Mos 的做法：复制原始事件作模板，只改写 pointDelta 并直投目标进程，兼容性最佳。
/// 全部逻辑均在主线程运行（tap 挂主 runloop、Timer 主线程、UI 主线程），故标记 @unchecked Sendable。
final class SmoothScrollEngine: ObservableObject, @unchecked Sendable {
    static let shared = SmoothScrollEngine()

    /// 合成事件标记，避免自己 post 的事件再次进入 tap 形成回环
    private static let syntheticMarker: Int64 = 0x4D_54_53_53 // 'MTSS'

    @Published private(set) var isRunning = false

    private var config = ScrollConfig.load()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var displayTimer: Timer?

    // 从被拦截事件复制的模板 + 目标进程（用于直投）
    private var template: CGEvent?
    private var targetPID: pid_t = 0

    // 动画状态：目标与已输出
    private var targetY = 0.0, targetX = 0.0
    private var emittedY = 0.0, emittedX = 0.0

    private init() {}

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    // MARK: - 生命周期

    func activateIfEnabled() {
        config = ScrollConfig.load()
        if config.enabled { start() } else { stop() }
    }

    func reload() {
        config = ScrollConfig.load()
        if config.enabled { start() } else { stop() }
    }

    func start() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollTapCallback,
            userInfo: refcon
        ) else {
            isRunning = false // 通常因缺少“辅助功能”权限而失败
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    func stop() {
        stopTimer()
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    // MARK: - 事件处理（主线程 runloop 回调）

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // 跳过自己合成的事件
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        // 触控板等连续事件不处理
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
            return Unmanaged.passUnretained(event)
        }

        let rawY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let rawX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)

        let handleV = config.smoothVertical && rawY != 0
        let handleH = config.smoothHorizontal && rawX != 0
        if !handleV && !handleH {
            return Unmanaged.passUnretained(event)
        }

        // 复制原始事件作为投递模板，并记录目标进程
        template = event.copy()
        targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))

        // 每一“行”换算的像素量（结合增益）
        let lineToPixel = 48.0 * config.gain
        if handleV {
            targetY += rawY * lineToPixel * (config.invertVertical ? -1 : 1)
        }
        if handleH {
            targetX += rawX * lineToPixel * (config.invertHorizontal ? -1 : 1)
        }
        startTimerIfNeeded()
        return nil // 消费原始事件
    }

    // MARK: - 缓动动画器

    private func startTimerIfNeeded() {
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
        targetY = 0; targetX = 0; emittedY = 0; emittedX = 0
        template = nil; targetPID = 0
    }

    private func tick() {
        let dt = 1.0 / 120.0
        let tau = max(0.04, config.duration / 4.0)
        let factor = 1 - exp(-dt / tau)

        var moveY = (targetY - emittedY) * factor
        var moveX = (targetX - emittedX) * factor
        moveY = clampStep(move: moveY, remaining: targetY - emittedY)
        moveX = clampStep(move: moveX, remaining: targetX - emittedX)

        emittedY += moveY
        emittedX += moveX

        if moveY != 0 || moveX != 0 {
            postScroll(y: moveY, x: moveX)
        }

        if abs(targetY - emittedY) < 0.1 && abs(targetX - emittedX) < 0.1 {
            stopTimer()
        }
    }

    private func clampStep(move: Double, remaining: Double) -> Double {
        guard abs(remaining) > config.minStep else { return remaining } // 收尾：一步到位
        if abs(move) < config.minStep {
            return move < 0 ? -config.minStep : config.minStep
        }
        return move
    }

    /// 复制模板事件，改写像素 delta 后直投目标进程（无模板时回退 session tap）
    private func postScroll(y: Double, x: Double) {
        guard let event = template?.copy() else { return }
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: y)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: x)
        // 清掉原 line delta，避免与 pixel delta 叠加造成跳动
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        // 模拟触控板：标记为连续事件，走 App 原生平滑滚动路径
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: config.touchpadEmulation ? 1 : 0)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        if targetPID > 0 {
            event.postToPid(targetPID)
        } else {
            event.post(tap: .cgSessionEventTap)
        }
    }
}

// CGEventTap C 回调：转发给引擎实例（tap 在主 runloop，回调即主线程）
private func scrollTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<SmoothScrollEngine>.fromOpaque(refcon).takeUnretainedValue()
    return engine.handle(type: type, event: event)
}
