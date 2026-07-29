import AppKit
import CoreGraphics

/// 平滑滚动引擎：CGEventTap 拦截鼠标滚轮，就地改写滚动量（速度增益 / 轴向反向 / 轴转换）后放行。
/// 不消费原事件、不注入合成事件，因此不依赖事件投递路由，前台/后台均稳定、绝不冻结。
/// 仅作用于鼠标滚轮（按 phase 判定跳过触控板），不影响触控板。
final class SmoothScrollEngine: ObservableObject, @unchecked Sendable {
    static let shared = SmoothScrollEngine()

    @Published private(set) var isRunning = false

    private var config = ScrollConfig.load()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activityToken: NSObjectProtocol?   // 阻止 App Nap 的活动令牌

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
            tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
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
        // 就地改写模式：不消费、不注入，无需 DisplayLink/看门狗；仅阻止 App Nap 保持后台 tap 响应
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "SmoothScroll")
        }
        isRunning = true
    }

    func stop() {
        if let token = activityToken { ProcessInfo.processInfo.endActivity(token); activityToken = nil }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
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
        if isTrackpad(event) {
            return Unmanaged.passUnretained(event)
        }
        // 目标是 MenuTools 自身窗口（如设置面板）时放行，避免自己的 ScrollView 滚不动
        if event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier) {
            return Unmanaged.passUnretained(event)
        }

        // 取可用位移（兼容行/像素两类鼠标）
        let (usableY, _) = usable(
            line: event.getDoubleValueField(.scrollWheelEventDeltaAxis1),
            pt: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        let (usableX, _) = usable(
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

        // 加速键按下 → 增益放大
        var accel = 1.0
        if config.accelModifier != 0 && (flags & UInt64(config.accelModifier)) == UInt64(config.accelModifier) {
            accel = 3.0
        }
        // 转换键按下 → 垂直滚动转为水平
        let shiftAxis = config.shiftModifier != 0 && (flags & UInt64(config.shiftModifier)) == UInt64(config.shiftModifier)
    
        // 各轴倍率：平滑开启的轴应用速度增益，反向则取负
        let multY = (config.smoothVertical ? config.gain : 1.0) * accel * (config.invertVertical ? -1.0 : 1.0)
        let multX = (config.smoothHorizontal ? config.gain : 1.0) * accel * (config.invertHorizontal ? -1.0 : 1.0)
    
        // 转换键：垂直滚动搬到水平轴
        if shiftAxis && usableY != 0 && usableX == 0 {
            let ptY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let fixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            let lineY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: ptY * multY)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixedY * multY)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64((lineY * multY).rounded()))
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            return Unmanaged.passUnretained(event)
        }
    
        // 垂直轴：就地改写三个 delta 字段
        if usableY != 0 && multY != 1.0 {
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) * multY)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * multY)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64((event.getDoubleValueField(.scrollWheelEventDeltaAxis1) * multY).rounded()))
        }
        // 水平轴
        if usableX != 0 && multX != 1.0 {
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) * multX)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * multX)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64((event.getDoubleValueField(.scrollWheelEventDeltaAxis2) * multX).rounded()))
        }
        // 就地改写后放行（不消费、不注入 → 投递绝不失败、绝不冻结）
        return Unmanaged.passUnretained(event)
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
