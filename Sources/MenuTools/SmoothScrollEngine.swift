import AppKit
import CoreGraphics
import CoreVideo
import QuartzCore
import os

/// 平滑滚动引擎：CGEventTap 拦截鼠标滚轮，用 CVDisplayLink 逐帧插值为平滑像素滚动。
/// 借鉴 Mos：buffer/current lerp 模型 + 峰值滤波去起始抖动 + 复制事件模板直投目标进程。
/// tap 回调在主线程、DisplayLink 回调在后台线程，共享滚动状态用 os_unfair_lock 保护。
final class SmoothScrollEngine: ObservableObject, @unchecked Sendable {
    static let shared = SmoothScrollEngine()

    private static let syntheticMarker: Int64 = 0x4D_54_53_53 // 'MTSS'

    @Published private(set) var isRunning = false

    private var config = ScrollConfig.load()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var displayLink: CVDisplayLink?

    // 共享滚动状态（锁保护）
    private var lock = os_unfair_lock_s()
    private var buffer = (y: 0.0, x: 0.0)   // 目标累计位移
    private var current = (y: 0.0, x: 0.0)  // 已输出位移
    private var lastDelta = (y: 0.0, x: 0.0)
    private var filter = ScrollFilter()
    private var template: CGEvent?
    private var targetPID: pid_t = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var active = false              // 动画是否进行中

    private init() {}

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    // MARK: - 生命周期

    func activateIfEnabled() { reload() }

    func reload() {
        config = ScrollConfig.load()
        if config.enabled { start() } else { stop() }
    }

    func start() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: scrollTapCallback, userInfo: refcon
        ) else {
            isRunning = false // 通常因缺少“辅助功能”权限
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        setupDisplayLink()
        isRunning = true
    }

    func stop() {
        if let link = displayLink { CVDisplayLinkStop(link) }
        displayLink = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        resetState()
        isRunning = false
    }

    // MARK: - 触控板判定（增强：不止看 isContinuous）

    private func isTrackpad(_ e: CGEvent) -> Bool {
        if e.getDoubleValueField(.scrollWheelEventMomentumPhase) != 0 { return true }
        if e.getDoubleValueField(.scrollWheelEventScrollPhase) != 0 { return true }
        if e.getDoubleValueField(.scrollWheelEventScrollCount) != 0 { return true }
        return e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    }

    // MARK: - 事件处理（主线程）

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        if isTrackpad(event) {
            return Unmanaged.passUnretained(event)
        }

        let rawY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let rawX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        let handleV = config.smoothVertical && rawY != 0
        let handleH = config.smoothHorizontal && rawX != 0
        if !handleV && !handleH {
            return Unmanaged.passUnretained(event)
        }

        let templateCopy = event.copy()
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        let lineToPixel = 48.0 * config.gain
        let dy = handleV ? rawY * lineToPixel * (config.invertVertical ? -1 : 1) : 0
        let dx = handleH ? rawX * lineToPixel * (config.invertHorizontal ? -1 : 1) : 0

        os_unfair_lock_lock(&lock)
        template = templateCopy
        targetPID = pid
        // 同向累加、反向重置（避免旧残余抵消造成滞后）
        if dy != 0 {
            if dy * lastDelta.y > 0 { buffer.y += dy } else { buffer.y = dy; current.y = 0 }
        }
        if dx != 0 {
            if dx * lastDelta.x > 0 { buffer.x += dx } else { buffer.x = dx; current.x = 0 }
        }
        lastDelta = (dy != 0 ? dy : lastDelta.y, dx != 0 ? dx : lastDelta.x)
        active = true
        os_unfair_lock_unlock(&lock)

        if let link = displayLink, !CVDisplayLinkIsRunning(link) {
            lastFrameTime = 0
            CVDisplayLinkStart(link)
        }
        return nil // 消费原始事件
    }

    // MARK: - CVDisplayLink 逐帧插值

    private func setupDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, inNow, _, _, _ in
            self?.frame(now: inNow.pointee)
            return kCVReturnSuccess
        }
        displayLink = link
    }

    private func frame(now: CVTimeStamp) {
        let t = CACurrentMediaTime()
        os_unfair_lock_lock(&lock)
        // 计算帧间隔与逐帧逼近系数
        let dt = lastFrameTime > 0 ? min(0.05, t - lastFrameTime) : 1.0 / 60.0
        lastFrameTime = t
        let tau = max(0.03, config.duration / 3.0)
        let trans = 1 - exp(-dt / tau)

        var frameY = (buffer.y - current.y) * trans
        var frameX = (buffer.x - current.x) * trans
        current.y += frameY
        current.x += frameX

        // 峰值滤波去起始抖动
        (frameY, frameX) = filter.fill(y: frameY, x: frameX)

        let deadZone = 0.1
        let residual = max(abs(buffer.y - current.y), abs(buffer.x - current.x))
        let output = max(abs(frameY), abs(frameX))

        let templateCopy = template?.copy()
        let pid = targetPID
        let continuous = config.touchpadEmulation

        if residual < deadZone && output < deadZone {
            // 收敛：停止并复位
            active = false
            buffer = (0, 0); current = (0, 0); lastDelta = (0, 0)
            filter.reset()
            os_unfair_lock_unlock(&lock)
            if let link = displayLink { CVDisplayLinkStop(link) }
            return
        }
        os_unfair_lock_unlock(&lock)

        if output > deadZone, let event = templateCopy {
            post(event: event, y: frameY, x: frameX, pid: pid, continuous: continuous)
        }
    }

    private func post(event: CGEvent, y: Double, x: Double, pid: pid_t, continuous: Bool) {
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: y)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: x)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        if pid > 0 { event.postToPid(pid) } else { event.post(tap: .cgSessionEventTap) }
    }

    private func resetState() {
        os_unfair_lock_lock(&lock)
        buffer = (0, 0); current = (0, 0); lastDelta = (0, 0)
        filter.reset(); template = nil; targetPID = 0; active = false
        os_unfair_lock_unlock(&lock)
    }
}

/// 峰值滤波：用非线性数列平滑每帧增量，去除滚动起始的生硬跳跃（借鉴 Mos ScrollFilter）
private struct ScrollFilter {
    private var winY = [0.0, 0.0]
    private var winX = [0.0, 0.0]

    mutating func fill(y: Double, x: Double) -> (Double, Double) {
        winY = polish(winY, with: y)
        winX = polish(winX, with: x)
        return (winY[0], winX[0])
    }

    mutating func reset() {
        winY = [0.0, 0.0]
        winX = [0.0, 0.0]
    }

    private func polish(_ array: [Double], with next: Double) -> [Double] {
        let first = array[1]
        let diff = next - first
        return [first, first + 0.23 * diff, first + 0.5 * diff, first + 0.77 * diff, next]
    }
}

// CGEventTap C 回调
private func scrollTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<SmoothScrollEngine>.fromOpaque(refcon).takeUnretainedValue()
    return engine.handle(type: type, event: event)
}
