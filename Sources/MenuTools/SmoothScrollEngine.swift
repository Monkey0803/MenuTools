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
    private var activityToken: NSObjectProtocol?   // 阻止 App Nap 的活动令牌
    // 专用投递队列（userInteractive）：避免在 CVDisplayLink 线程同步投递，后台时不被降权限流
    private let postQueue = DispatchQueue(label: "com.qoder.menutools.scrollpost", qos: .userInteractive)

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
        // DisplayLink 常驻运行（绝不在回调线程里 stop，避免 link 卡死）；空闲时不投递
        if let link = displayLink { CVDisplayLinkStart(link) }
        // 阻止 App Nap：后台无窗口时 macOS 会节流本进程，导致 postToPid 投递的事件不被路由
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "SmoothScroll")
        }
        isRunning = true
    }

    func stop() {
        if let token = activityToken { ProcessInfo.processInfo.endActivity(token); activityToken = nil }
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

    // MARK: - 触控板判定

    /// 只有带 phase 的才是触控板（真触控板滚动时必带 scroll/momentum phase）。
    /// 高精度鼠标虽然 isContinuous=1，但 phase 恒为 0，因此不能单靠 isContinuous 判定。
    private func isTrackpad(_ e: CGEvent) -> Bool {
        if e.getDoubleValueField(.scrollWheelEventScrollPhase) != 0 { return true }
        if e.getDoubleValueField(.scrollWheelEventMomentumPhase) != 0 { return true }
        return false
    }

    /// 取某轴可用位移：优先像素 delta（高精度鼠标），其次定点，最后行 delta。
    /// 返回（值, 是否像素源）；行源需放大更多才能达到相似手感。
    private func usable(line: Double, pt: Double, fixed: Double) -> (value: Double, pixel: Bool) {
        if pt != 0 { return (pt, true) }
        if fixed != 0 { return (fixed, true) }
        return (line, false)
    }

    // MARK: - 事件处理（主线程）

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if marker == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        if isTrackpad(event) {
            return Unmanaged.passUnretained(event)
        }
        // 目标是 MenuTools 自身窗口（如设置面板）时放行，避免自己的 ScrollView 滚不动
        if event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier) {
            return Unmanaged.passUnretained(event)
        }

        // 取可用位移（兼容行/像素两类鼠标）
        let (usableY, pixelY) = usable(
            line: event.getDoubleValueField(.scrollWheelEventDeltaAxis1),
            pt: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        let (usableX, pixelX) = usable(
            line: event.getDoubleValueField(.scrollWheelEventDeltaAxis2),
            pt: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
            fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        if usableY == 0 && usableX == 0 {
            return Unmanaged.passUnretained(event)
        }

        // 禁用键按下 → 完全放行
        let flags = event.flags.rawValue
        if config.disableModifier != 0 && (flags & UInt64(config.disableModifier)) == UInt64(config.disableModifier) {
            return Unmanaged.passUnretained(event)
        }

        let smoothV = config.smoothVertical && usableY != 0
        let smoothH = config.smoothHorizontal && usableX != 0
        let reverseV = config.invertVertical && usableY != 0
        let reverseH = config.invertHorizontal && usableX != 0

        // 无任何平滑：若需反向则翻转原事件三个 delta 字段并放行
        if !smoothV && !smoothH {
            if reverseV {
                event.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: -event.getDoubleValueField(.scrollWheelEventDeltaAxis1))
                event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
            }
            if reverseH {
                event.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: -event.getDoubleValueField(.scrollWheelEventDeltaAxis2))
                event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
            }
            return Unmanaged.passUnretained(event)
        }

        // 加速键按下 → 增益放大
        var accel = 1.0
        if config.accelModifier != 0 && (flags & UInt64(config.accelModifier)) == UInt64(config.accelModifier) {
            accel = 3.0
        }
        // 转换键按下 → 垂直滚动转为水平
        let shiftAxis = config.shiftModifier != 0 && (flags & UInt64(config.shiftModifier)) == UInt64(config.shiftModifier)

        let templateCopy = event.copy()
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        // 像素源已是像素，用较小倍率；行源需放大到像素
        let scaleY = pixelY ? 4.0 : 48.0
        let scaleX = pixelX ? 4.0 : 48.0
        var dy = smoothV ? usableY * config.gain * accel * scaleY * (reverseV ? -1 : 1) : 0
        var dx = smoothH ? usableX * config.gain * accel * scaleX * (reverseH ? -1 : 1) : 0
        if shiftAxis && dy != 0 && dx == 0 {
            dx = dy   // 垂直量搬到水平轴
            dy = 0
        }

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
            // 收敛：复位状态（不停 DisplayLink）
            buffer = (0, 0); current = (0, 0); lastDelta = (0, 0)
            filter.reset()
            lastFrameTime = 0
            active = false
            os_unfair_lock_unlock(&lock)
            return
        }
        let willPost = output > deadZone
        os_unfair_lock_unlock(&lock)

        if willPost, let event = templateCopy {
            post(event: event, y: frameY, x: frameX, pid: pid, continuous: continuous)
        }
    }

    private func post(event: CGEvent, y: Double, x: Double, pid: pid_t, continuous: Bool) {
        // 回到已知可用的最小格式：只写 pointDelta + 清零行 delta，不碰 fixedPtDelta/phase
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: y)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: x)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        let e = event
        postQueue.async {
            if pid > 0 { e.postToPid(pid) } else { e.post(tap: .cgSessionEventTap) }
        }
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
