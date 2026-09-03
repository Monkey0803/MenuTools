import AppKit
import CoreGraphics
import Darwin
import IOKit

/// 决定全局滚动钩子是否接管事件。MenuTools 自己的可交互窗口必须保留原始事件，
/// 否则 SwiftUI 的滚动视图会收不到被全局钩子重新注入的事件。
enum SmoothScrollTargetPolicy {
    static func shouldTransform(
        frontmostProcessIdentifier: Int32?,
        ownProcessIdentifier: Int32,
        hasVisibleOwnWindow: Bool = false
    ) -> Bool {
        frontmostProcessIdentifier != ownProcessIdentifier && !hasVisibleOwnWindow
    }
}

/// HID 事件有硬件来源时，设备身份比滚动 phase 更可靠：MX Master 2S 的自由滚轮也会带 phase。
enum ScrollDeviceClassifier {
    static func isTrackpad(productName: String?, hasHIDSender: Bool, hasScrollPhase: Bool) -> Bool {
        guard hasHIDSender else { return hasScrollPhase }
        return productName?.localizedCaseInsensitiveContains("trackpad") ?? false
    }
}

/// OpenLogi 只对离散滚轮刻度生成有限动画。连续像素流（触控板或 Logitech
/// 自由滚轮）已经携带系统精确度，重新合成反而会造成距离和跟手感退化。
enum SmoothScrollInputPolicy {
    static func shouldAnimate(isTrackpad: Bool, isContinuous: Bool) -> Bool {
        !isTrackpad && !isContinuous
    }
}

/// 将鼠标的三个滚动字段归一为像素距离。
/// 某些高精度鼠标同时上报很小的 point 值和传统的 line 刻度；前者若直接拿来
/// 注入会让一格滚轮只移动 1px，因此以用户设置的每格最短步长为准。
enum ScrollDeltaNormalizer {
    static func pixels(line: Double, point: Double, fixed: Double, lineEquivalent: Double) -> Double {
        let step = lineEquivalent.isFinite ? max(lineEquivalent, 1) : 8
        if line != 0, (point == 0 || abs(point) < abs(line) * step) {
            return line * step
        }
        if point != 0 { return point }
        if fixed != 0 { return fixed }
        return 0
    }
}

/// 设置界面与后台 HID 线程之间的配置交接；滚动回调只读取一个完整快照。
final class SmoothScrollConfigurationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ScrollConfig

    init(_ initial: ScrollConfig) {
        value = initial
    }

    func replace(with value: ScrollConfig) {
        lock.withLock { self.value = value }
    }

    func snapshot() -> ScrollConfig {
        lock.withLock { value }
    }
}

/// 用 CoreGraphics/IOKit 的长期存在私有符号获取输入设备名称。
/// 若系统符号或注册表查询不可用则返回 nil，调用方会安全地降级到 phase 判断。
private enum HIDEventInspector {
    private typealias CopyHIDEvent = @convention(c) (CGEvent) -> UnsafeMutableRawPointer?
    private typealias GetSenderID = @convention(c) (UnsafeMutableRawPointer) -> UInt64

    private struct DeviceInfo {
        let productName: String?
    }

    private final class DeviceCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UInt64: DeviceInfo] = [:]

        func value(for senderID: UInt64) -> DeviceInfo? {
            lock.withLock { values[senderID] }
        }

        func store(_ value: DeviceInfo, for senderID: UInt64) {
            lock.withLock { values[senderID] = value }
        }
    }

    private static let copyHIDEvent: CopyHIDEvent? = loadSymbol(
        framework: "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        name: "CGEventCopyIOHIDEvent"
    )
    private static let getSenderID: GetSenderID? = loadSymbol(
        framework: "/System/Library/Frameworks/IOKit.framework/IOKit",
        name: "IOHIDEventGetSenderID"
    )
    private static let deviceCache = DeviceCache()

    static func productName(for event: CGEvent) -> (hasHIDSender: Bool, productName: String?) {
        guard let copyHIDEvent, let getSenderID, let hidEvent = copyHIDEvent(event) else {
            return (false, nil)
        }
        defer { Unmanaged<AnyObject>.fromOpaque(hidEvent).release() }

        let senderID = getSenderID(hidEvent)
        if let cached = deviceCache.value(for: senderID) {
            return (true, cached.productName)
        }

        let info = DeviceInfo(productName: registryProductName(senderID: senderID))
        deviceCache.store(info, for: senderID)
        return (true, info.productName)
    }

    private static func registryProductName(senderID: UInt64) -> String? {
        guard let matching = IORegistryEntryIDMatching(senderID) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntrySearchCFProperty(
            service,
            "IOService",
            "Product" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        ) as? String
    }

    private static func loadSymbol<T>(framework: String, name: String) -> T? {
        guard let handle = dlopen(framework, RTLD_LAZY | RTLD_LOCAL),
              let symbol = dlsym(handle, name) else {
            return nil
        }
        // 保持 framework handle 存活；系统 framework 进程退出时统一回收。
        return unsafeBitCast(symbol, to: T.self)
    }
}

/// 二维滚动位移。所有平滑动画均以像素为单位，避免把传统滚轮刻度和连续滚动混在一起。
struct ScrollVector: Sendable, Equatable {
    static let zero = ScrollVector(x: 0, y: 0)

    var x: Double
    var y: Double

    var isZero: Bool { x == 0 && y == 0 }
    var isFinite: Bool { x.isFinite && y.isFinite }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    func approximatelyEquals(_ other: Self, accuracy: Double = 0.000_001) -> Bool {
        abs(x - other.x) <= accuracy && abs(y - other.y) <= accuracy
    }
}

/// 将分帧的浮点位移量化为系统事件可表达的整数像素，并把舍入误差带到下一帧。
struct ScrollQuantizer: Sendable {
    private var residual = ScrollVector.zero

    mutating func quantize(_ delta: ScrollVector) -> ScrollVector {
        guard delta.isFinite else { return .zero }
        let exact = residual + delta
        let output = ScrollVector(
            x: min(max(exact.x.rounded(), Double(Int32.min)), Double(Int32.max)),
            y: min(max(exact.y.rounded(), Double(Int32.min)), Double(Int32.max))
        )
        residual = exact - output
        return output
    }
}

/// OpenLogi 风格的有限平滑动画模型。
///
/// 新的滚动输入会从当前实际位置重新定向至累计目标，而非排队播放，快速拨动也不会越滚越慢或丢失距离。
struct SmoothScrollMotion: Sendable {
    private struct Segment: Sendable {
        var from: ScrollVector
        var target: ScrollVector
        var startedAt: TimeInterval
    }

    private var segment: Segment?
    private var emitted = ScrollVector.zero
    private let duration: TimeInterval

    init(duration: TimeInterval) {
        self.duration = duration.isFinite ? max(duration, 0.001) : 0.1
    }

    var isIdle: Bool { segment == nil }

    /// 将 `delta` 加入累计目标，并返回在重定向前必须先发出的旧动画余量。
    @discardableResult
    mutating func retarget(by delta: ScrollVector, at time: TimeInterval) -> ScrollVector {
        guard delta.isFinite, !delta.isZero else { return .zero }

        let position = position(at: time)
        let flushed = position - emitted
        emitted = position
        let priorTarget = segment?.target ?? position
        segment = Segment(from: position, target: priorTarget + delta, startedAt: time)
        return flushed
    }

    /// 前进至 `time`，返回自上次输出后的增量；完成时会保留精确的末尾余量。
    mutating func advance(to time: TimeInterval) -> ScrollVector {
        guard let segment else { return .zero }
        let position = position(at: time)
        let delta = position - emitted
        emitted = position
        if hasFinished(segment, at: time) {
            self.segment = nil
        }
        return delta
    }

    func isFinished(at time: TimeInterval) -> Bool {
        guard let segment else { return true }
        return hasFinished(segment, at: time)
    }

    private func position(at time: TimeInterval) -> ScrollVector {
        guard let segment else { return emitted }
        let progress = min(max((time - segment.startedAt) / duration, 0), 1)
        // cubic smoothstep：起止速度为零，适合带物理棘轮的 MX Master 2S。
        let eased = progress * progress * (3 - 2 * progress)
        return ScrollVector(
            x: segment.from.x + (segment.target.x - segment.from.x) * eased,
            y: segment.from.y + (segment.target.y - segment.from.y) * eased
        )
    }

    private func hasFinished(_ segment: Segment, at time: TimeInterval) -> Bool {
        // TimeInterval 是 Double，避免 0.15 - 0.05 这类可表示误差把最后一帧永久留在活动状态。
        time >= segment.startedAt + duration - 0.000_000_001
    }
}

private enum SmoothScrollPhase {
    case began
    case changed
    case ended
    case cancelled
}

private struct ScrollOutputStyle: Sendable {
    var continuous: Bool
    var pointsPerLine: Double

    init(continuous: Bool, pointsPerLine: Double) {
        self.continuous = continuous
        self.pointsPerLine = pointsPerLine.isFinite ? max(pointsPerLine, 1) : 8
    }
}

/// 独占一个串行队列的输出器。CGEventTap 回调只提交输入，绝不等待计时或事件注入。
private final class SmoothScrollAnimator: @unchecked Sendable {
    private static let frameInterval = DispatchTimeInterval.milliseconds(8)

    private let queue = DispatchQueue(label: "com.menutools.smooth-scroll", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var motion = SmoothScrollMotion(duration: 0.1)
    private var quantizer = ScrollQuantizer()
    private var outputActive = false
    private var style = ScrollOutputStyle(continuous: true, pointsPerLine: 8)

    func submit(_ delta: ScrollVector, duration: TimeInterval, style: ScrollOutputStyle) {
        guard delta.isFinite, !delta.isZero else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.motion.isIdle {
                // 新一段采用最新配置；进行中的动画不改时长，避免截断已累计的距离。
                self.style = style
                self.motion = SmoothScrollMotion(duration: duration)
                _ = self.motion.retarget(by: delta, at: now)
            } else if self.motion.isFinished(at: now) {
                // 计时器尚未来得及发出末帧时，先结清旧距离再开始新的手势。
                self.emit(self.motion.advance(to: now), terminal: true)
                self.style = style
                self.motion = SmoothScrollMotion(duration: duration)
                _ = self.motion.retarget(by: delta, at: now)
            } else {
                let flushed = self.motion.retarget(by: delta, at: now)
                self.emit(flushed, terminal: false)
            }
            self.ensureTimer()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.setEventHandler {}
            self.timer?.cancel()
            self.timer = nil
            self.motion = SmoothScrollMotion(duration: 0.1)
            self.quantizer = ScrollQuantizer()
            if self.outputActive {
                SmoothScrollEngine.postSynthetic(.zero, phase: .cancelled, style: self.style)
                self.outputActive = false
            }
        }
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.frameInterval, repeating: Self.frameInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let finishes = motion.isFinished(at: now)
        let delta = motion.advance(to: now)
        emit(delta, terminal: finishes)
        if finishes {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
        }
    }

    private func emit(_ delta: ScrollVector, terminal: Bool) {
        guard delta.isFinite else { return }
        let quantized = quantizer.quantize(delta)
        if terminal {
            if outputActive {
                SmoothScrollEngine.postSynthetic(quantized, phase: .ended, style: style)
                outputActive = false
            } else if !delta.isZero {
                SmoothScrollEngine.postSynthetic(quantized, phase: .began, style: style)
                SmoothScrollEngine.postSynthetic(.zero, phase: .ended, style: style)
            }
        } else if !delta.isZero {
            let phase: SmoothScrollPhase = outputActive ? .changed : .began
            SmoothScrollEngine.postSynthetic(quantized, phase: phase, style: style)
            outputActive = true
        }
    }
}

/// HID 事件必须运行在独立 RunLoop 上。MenuTools 退到后台时主 RunLoop 可能被系统降速，
/// 会使鼠标输入滞后；专用线程让事件采集与前台状态无关。
private final class SmoothScrollTapRunner: @unchecked Sendable {
    private final class InstallContext: @unchecked Sendable {
        let userInfo: UnsafeMutableRawPointer

        init(userInfo: UnsafeMutableRawPointer) {
            self.userInfo = userInfo
        }
    }

    private let stateLock = NSLock()
    private var eventTap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var isStarting = false
    private let startupSignal = DispatchSemaphore(value: 0)

    var isRunning: Bool {
        stateLock.withLock { eventTap != nil }
    }

    func start(userInfo: UnsafeMutableRawPointer) -> Bool {
        guard stateLock.withLock({ () -> Bool in
            guard eventTap == nil, !isStarting else { return false }
            isStarting = true
            return true
        }) else {
            return isRunning
        }

        let context = InstallContext(userInfo: userInfo)
        let thread = Thread { [weak self] in
            self?.installAndRun(context: context)
        }
        thread.name = "com.menutools.smooth-scroll.tap"
        thread.qualityOfService = .userInteractive
        stateLock.withLock { self.thread = thread }
        thread.start()

        guard startupSignal.wait(timeout: .now() + 2) == .success else {
            return false
        }
        return isRunning
    }

    func stop() {
        let state = stateLock.withLock { (runLoop, eventTap, source) }
        guard let runLoop = state.0 else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            if let tap = state.1 { CGEvent.tapEnable(tap: tap, enable: false) }
            if let source = state.2 {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            CFRunLoopStop(CFRunLoopGetCurrent())
            self.stateLock.withLock {
                self.eventTap = nil
                self.source = nil
                self.runLoop = nil
                self.thread = nil
                self.isStarting = false
            }
        }
        CFRunLoopWakeUp(runLoop)
    }

    func reenable() {
        let tap = stateLock.withLock { eventTap }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func installAndRun(context: InstallContext) {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollTapCallback,
            userInfo: context.userInfo
        ) else {
            stateLock.withLock { isStarting = false }
            startupSignal.signal()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        stateLock.withLock {
            self.eventTap = tap
            self.source = source
            self.runLoop = runLoop
            self.isStarting = false
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        startupSignal.signal()
        CFRunLoopRun()
    }
}

/// 平滑滚动引擎：消费传统鼠标滚轮事件，在后台将其注入为带完整 phase 的连续像素滚动事件。
/// 触控板与 MenuTools 自身窗口的滚动始终放行。
final class SmoothScrollEngine: ObservableObject, @unchecked Sendable {
    static let shared = SmoothScrollEngine()

    @Published private(set) var isRunning = false

    private static let syntheticEventUserData: Int64 = 0x4D54_5343 // "MTSC"

    private let configurationStore = SmoothScrollConfigurationStore(ScrollConfig.load())
    private let tapRunner = SmoothScrollTapRunner()
    private var activityToken: NSObjectProtocol?
    private let animator = SmoothScrollAnimator()

    private init() {}

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    // MARK: - 生命周期

    func activateIfEnabled() { reload() }

    func reload() {
        let config = ScrollConfig.load()
        configurationStore.replace(with: config)
        if config.enabled { start() } else { stop() }
    }

    func start() {
        guard !tapRunner.isRunning else {
            isRunning = true
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard tapRunner.start(userInfo: refcon) else {
            isRunning = false
            return
        }
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "SmoothScroll")
        }
        isRunning = true
    }

    func stop() {
        animator.cancel()
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        tapRunner.stop()
        isRunning = false
    }

    // MARK: - 事件处理

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tapRunner.reenable()
            return Unmanaged.passUnretained(event)
        }
        let config = configurationStore.snapshot()
        let isTrackpad = isTrackpad(event)
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        guard config.enabled,
              event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventUserData,
              SmoothScrollInputPolicy.shouldAnimate(isTrackpad: isTrackpad, isContinuous: isContinuous),
              SmoothScrollTargetPolicy.shouldTransform(
                frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier
              )
        else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags.rawValue
        if config.disableModifier != 0,
           (flags & UInt64(config.disableModifier)) == UInt64(config.disableModifier) {
            return Unmanaged.passUnretained(event)
        }
        let acceleration = config.accelModifier != 0 &&
            (flags & UInt64(config.accelModifier)) == UInt64(config.accelModifier) ? 3.0 : 1.0

        let vertical = ScrollAxis(event: event, axis: 1, lineEquivalent: config.minStep)
        let horizontal = ScrollAxis(event: event, axis: 2, lineEquivalent: config.minStep)
        guard !vertical.pixels.isZero || !horizontal.pixels.isZero else {
            return Unmanaged.passUnretained(event)
        }

        if config.shiftModifier != 0,
           (flags & UInt64(config.shiftModifier)) == UInt64(config.shiftModifier),
           !vertical.pixels.isZero,
           horizontal.pixels.isZero {
            return processShiftAxis(event: event, vertical: vertical, config: config, acceleration: acceleration)
        }

        let yMultiplier = multiplier(
            smooth: config.smoothVertical,
            inverted: config.invertVertical,
            gain: config.gain,
            acceleration: acceleration
        )
        let xMultiplier = multiplier(
            smooth: config.smoothHorizontal,
            inverted: config.invertHorizontal,
            gain: config.gain,
            acceleration: acceleration
        )
        let smooth = ScrollVector(
            x: config.smoothHorizontal ? horizontal.pixels.x * xMultiplier : 0,
            y: config.smoothVertical ? vertical.pixels.y * yMultiplier : 0
        )
        if config.smoothVertical { vertical.clear(on: event) }
        else { vertical.scale(on: event, by: yMultiplier) }
        if config.smoothHorizontal { horizontal.clear(on: event) }
        else { horizontal.scale(on: event, by: xMultiplier) }

        if !smooth.isZero {
            animator.submit(
                smooth,
                duration: config.duration,
                style: ScrollOutputStyle(continuous: config.touchpadEmulation, pointsPerLine: config.minStep)
            )
        }
        // 有未平滑的轴就交给系统；否则消费原滚轮，避免与合成事件重复。
        return config.smoothVertical || config.smoothHorizontal ?
            (config.smoothVertical && config.smoothHorizontal ? nil : Unmanaged.passUnretained(event)) :
            Unmanaged.passUnretained(event)
    }

    private func processShiftAxis(
        event: CGEvent,
        vertical: ScrollAxis,
        config: ScrollConfig,
        acceleration: Double
    ) -> Unmanaged<CGEvent>? {
        let multiplier = multiplier(
            smooth: config.smoothVertical,
            inverted: config.invertVertical,
            gain: config.gain,
            acceleration: acceleration
        )
        if config.smoothVertical {
            vertical.clear(on: event)
            animator.submit(
                ScrollVector(x: vertical.pixels.y * multiplier, y: 0),
                duration: config.duration,
                style: ScrollOutputStyle(continuous: config.touchpadEmulation, pointsPerLine: config.minStep)
            )
            return nil
        }
        vertical.moveToHorizontal(on: event, by: multiplier)
        return Unmanaged.passUnretained(event)
    }

    private func multiplier(smooth: Bool, inverted: Bool, gain: Double, acceleration: Double) -> Double {
        let configuredGain = smooth ? gain : 1
        return configuredGain * acceleration * (inverted ? -1 : 1)
    }

    /// 有 HID 来源时按注册表中的设备名判断。高精度鼠标（尤其是 MX Master 2S）可能
    /// 带有和触控板相同的 phase，只有无来源的合成事件才退回到 phase 判断。
    private func isTrackpad(_ event: CGEvent) -> Bool {
        let device = HIDEventInspector.productName(for: event)
        let hasScrollPhase = event.getDoubleValueField(.scrollWheelEventScrollPhase) != 0 ||
            event.getDoubleValueField(.scrollWheelEventMomentumPhase) != 0
        return ScrollDeviceClassifier.isTrackpad(
            productName: device.productName,
            hasHIDSender: device.hasHIDSender,
            hasScrollPhase: hasScrollPhase
        )
    }

    fileprivate static func postSynthetic(_ delta: ScrollVector, phase: SmoothScrollPhase, style: ScrollOutputStyle) {
        guard delta.isFinite,
              let source = CGEventSource(stateID: .hidSystemState)
        else { return }

        let unit: CGScrollEventUnit = style.continuous ? .pixel : .line
        let pointsX = Int64(delta.x)
        let pointsY = Int64(delta.y)
        let lineX = style.continuous ? pointsX : Int64((Double(pointsX) / style.pointsPerLine).rounded())
        let lineY = style.continuous ? pointsY : Int64((Double(pointsY) / style.pointsPerLine).rounded())
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: unit,
            wheelCount: 2,
            wheel1: Int32(clamping: lineY),
            wheel2: Int32(clamping: lineX),
            wheel3: 0
        ) else { return }

        if style.continuous {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: pointsY)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: pointsX)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: pointsY / 10)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: pointsX / 10)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: pointsY * (1 << 16) / 10)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: pointsX * (1 << 16) / 10)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.cgValue)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        }
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventUserData)
        event.post(tap: .cghidEventTap)
    }
}

private extension SmoothScrollPhase {
    var cgValue: Int64 {
        switch self {
        case .began: 1
        case .changed: 2
        case .ended: 4
        case .cancelled: 8
        }
    }
}

/// 保存某一轴的原始事件字段，既可清除供平滑器接管，也可原地缩放后立即放行。
private struct ScrollAxis {
    let axis: Int
    let line: Double
    let point: Double
    let fixed: Double
    let pixels: ScrollVector

    init(event: CGEvent, axis: Int, lineEquivalent: Double) {
        self.axis = axis
        let fields = Self.fields(for: axis)
        line = event.getDoubleValueField(fields.line)
        point = event.getDoubleValueField(fields.point)
        fixed = event.getDoubleValueField(fields.fixed)
        let value = ScrollDeltaNormalizer.pixels(
            line: line,
            point: point,
            fixed: fixed,
            lineEquivalent: lineEquivalent
        )
        pixels = axis == 1 ? ScrollVector(x: 0, y: value) : ScrollVector(x: value, y: 0)
    }

    func clear(on event: CGEvent) {
        let fields = Self.fields(for: axis)
        event.setIntegerValueField(fields.line, value: 0)
        event.setDoubleValueField(fields.point, value: 0)
        event.setDoubleValueField(fields.fixed, value: 0)
    }

    func scale(on event: CGEvent, by multiplier: Double) {
        guard multiplier != 1 else { return }
        let fields = Self.fields(for: axis)
        event.setIntegerValueField(fields.line, value: Int64((line * multiplier).rounded()))
        event.setDoubleValueField(fields.point, value: point * multiplier)
        event.setDoubleValueField(fields.fixed, value: fixed * multiplier)
    }

    func moveToHorizontal(on event: CGEvent, by multiplier: Double) {
        clear(on: event)
        let target = Self.fields(for: 2)
        event.setIntegerValueField(target.line, value: Int64((line * multiplier).rounded()))
        event.setDoubleValueField(target.point, value: point * multiplier)
        event.setDoubleValueField(target.fixed, value: fixed * multiplier)
    }

    private static func fields(for axis: Int) -> (line: CGEventField, point: CGEventField, fixed: CGEventField) {
        axis == 1 ? (
            .scrollWheelEventDeltaAxis1,
            .scrollWheelEventPointDeltaAxis1,
            .scrollWheelEventFixedPtDeltaAxis1
        ) : (
            .scrollWheelEventDeltaAxis2,
            .scrollWheelEventPointDeltaAxis2,
            .scrollWheelEventFixedPtDeltaAxis2
        )
    }
}

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
