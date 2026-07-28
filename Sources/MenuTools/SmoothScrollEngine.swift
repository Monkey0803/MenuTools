import AppKit
import CoreGraphics

/// 平滑滚动引擎：用 CGEventTap 拦截鼠标滚轮，插值为平滑的像素级滚动。
/// 仅处理鼠标滚轮（非连续事件），触控板/合成事件原样放行。需“辅助功能”权限。
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

    // 动画状态：目标与已输出（含亚像素进位）
    private var targetY = 0.0, targetX = 0.0
    private var emittedY = 0.0, emittedX = 0.0
    private var carryY = 0.0, carryX = 0.0

    private init() {}

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    // MARK: - 生命周期

    func activateIfEnabled() {
        config = ScrollConfig.load()
        if config.enabled { start() } else { stop() }
    }

    /// 配置变化时重载
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
            // 通常因缺少“辅助功能”权限而失败
            isRunning = false
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
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    // MARK: - 事件处理（在主线程 runloop 回调，非 async）

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // tap 被系统禁用时重新启用
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
        // 两轴都不处理则整体放行
        if !handleV && !handleH {
            return Unmanaged.passUnretained(event)
        }

        // 一行约等于的像素量（结合增益）
        let lineToPixel = 16.0 * config.gain
        if handleV {
            let dir = config.invertVertical ? -1.0 : 1.0
            targetY += rawY * lineToPixel * dir
        }
        if handleH {
            let dir = config.invertHorizontal ? -1.0 : 1.0
            targetX += rawX * lineToPixel * dir
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
        targetY = 0; targetX = 0; emittedY = 0; emittedX = 0; carryY = 0; carryX = 0
    }

    private func tick() {
        let dt = 1.0 / 120.0
        // 时间常数：duration 内基本走完，tau 越小越快
        let tau = max(0.05, config.duration / 4.0)
        let factor = 1 - exp(-dt / tau)

        var moveY = (targetY - emittedY) * factor
        var moveX = (targetX - emittedX) * factor

        // 最短步长：剩余较大时保证每帧至少走 minStep，避免末端拖沓
        moveY = clampStep(move: moveY, remaining: targetY - emittedY)
        moveX = clampStep(move: moveX, remaining: targetX - emittedX)

        emittedY += moveY
        emittedX += moveX

        // 亚像素进位，取整后 post
        carryY += moveY
        carryX += moveX
        let intY = carryY.rounded(.towardZero)
        let intX = carryX.rounded(.towardZero)
        carryY -= intY
        carryX -= intX

        if intY != 0 || intX != 0 {
            postScroll(y: Int32(intY), x: Int32(intX))
        }

        // 收敛判定
        if abs(targetY - emittedY) < 0.5 && abs(targetX - emittedX) < 0.5 {
            stopTimer()
        }
    }

    private func clampStep(move: Double, remaining: Double) -> Double {
        guard abs(remaining) > config.minStep else { return move }
        if abs(move) < config.minStep {
            return move < 0 ? -config.minStep : config.minStep
        }
        return move
    }

    private func postScroll(y: Int32, x: Int32) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: y,   // 垂直
            wheel2: x,   // 水平
            wheel3: 0
        ) else { return }
        // 模拟触控板：标记为连续事件，让 App 走原生平滑滚动路径
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: config.touchpadEmulation ? 1 : 0)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.post(tap: .cgSessionEventTap)
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
