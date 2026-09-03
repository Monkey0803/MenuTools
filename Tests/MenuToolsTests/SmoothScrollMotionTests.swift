import Testing
@testable import MenuTools

@Test("平滑滚动以有限时长输出完整位移")
func smoothScrollMotionEmitsAnEasedFiniteDistance() {
    var motion = SmoothScrollMotion(duration: 0.1)
    motion.retarget(by: ScrollVector(x: 0, y: 10), at: 0)

    #expect(motion.advance(to: 0) == .zero)
    #expect(motion.advance(to: 0.05).approximatelyEquals(ScrollVector(x: 0, y: 5)))
    #expect(motion.advance(to: 0.1).approximatelyEquals(ScrollVector(x: 0, y: 5)))
    #expect(motion.isFinished(at: 0.1))
}

@Test("滚动输入抵达时会从当前位置重新定向且不丢失距离")
func smoothScrollMotionRetargetsWithoutLosingDistance() {
    var motion = SmoothScrollMotion(duration: 0.1)
    motion.retarget(by: ScrollVector(x: 0, y: 10), at: 0)
    let flushed = motion.retarget(by: ScrollVector(x: 0, y: 10), at: 0.05)

    #expect(flushed.approximatelyEquals(ScrollVector(x: 0, y: 5)))
    #expect(motion.advance(to: 0.15).approximatelyEquals(ScrollVector(x: 0, y: 15)))
    #expect(motion.isFinished(at: 0.15))
}

@Test("分帧注入会保留不足一个像素的小数距离")
func scrollQuantizerPreservesFractionalDistanceAcrossFrames() {
    var quantizer = ScrollQuantizer()

    #expect(quantizer.quantize(ScrollVector(x: 0, y: 0.4)) == .zero)
    #expect(quantizer.quantize(ScrollVector(x: 0, y: 0.4)) == ScrollVector(x: 0, y: 1))
    #expect(quantizer.quantize(ScrollVector(x: 0, y: 0.2)) == .zero)
}

@Test("MenuTools 成为前台应用时保留原始滚动事件")
func smoothScrollTargetPolicyLeavesOwnFrontmostApplicationUntouched() {
    #expect(!SmoothScrollTargetPolicy.shouldTransform(frontmostProcessIdentifier: 42, ownProcessIdentifier: 42))
    #expect(!SmoothScrollTargetPolicy.shouldTransform(
        frontmostProcessIdentifier: 7,
        ownProcessIdentifier: 42,
        hasVisibleOwnWindow: true
    ))
    #expect(SmoothScrollTargetPolicy.shouldTransform(frontmostProcessIdentifier: 7, ownProcessIdentifier: 42))
    #expect(SmoothScrollTargetPolicy.shouldTransform(frontmostProcessIdentifier: nil, ownProcessIdentifier: 42))
}

@Test("有硬件来源时以设备身份而非 phase 判断触控板")
func scrollDeviceClassifierPrefersKnownDeviceIdentityOverPhase() {
    #expect(!ScrollDeviceClassifier.isTrackpad(productName: "MX Master 2S", hasHIDSender: true, hasScrollPhase: true))
    #expect(ScrollDeviceClassifier.isTrackpad(productName: "MacBook Pro Trackpad", hasHIDSender: true, hasScrollPhase: false))
    #expect(ScrollDeviceClassifier.isTrackpad(productName: nil, hasHIDSender: false, hasScrollPhase: true))
}

@Test("带传统滚轮刻度的高精度鼠标使用设置的最短步长")
func scrollDeltaNormalizerAppliesMinimumStepToMouseDetents() {
    #expect(ScrollDeltaNormalizer.pixels(line: 1, point: 1, fixed: 1, lineEquivalent: 8) == 8)
    #expect(ScrollDeltaNormalizer.pixels(line: -2, point: 0, fixed: 0, lineEquivalent: 8) == -16)
    #expect(ScrollDeltaNormalizer.pixels(line: 0, point: 1, fixed: 1, lineEquivalent: 8) == 1)
    #expect(ScrollDeltaNormalizer.pixels(line: 1, point: 12, fixed: 12, lineEquivalent: 8) == 12)
}

@Test("后台事件 tap 读取完整且最新的滚动配置快照")
func smoothScrollConfigurationStorePublishesLatestConfiguration() {
    let initial = ScrollConfig(
        enabled: true, smoothVertical: true, smoothHorizontal: true,
        invertVertical: false, invertHorizontal: false, gain: 1,
        duration: 0.1, minStep: 8, touchpadEmulation: true,
        accelModifier: 0, shiftModifier: 0, disableModifier: 0
    )
    let updated = ScrollConfig(
        enabled: true, smoothVertical: true, smoothHorizontal: true,
        invertVertical: false, invertHorizontal: false, gain: 3,
        duration: 0.05, minStep: 16, touchpadEmulation: true,
        accelModifier: 0, shiftModifier: 0, disableModifier: 0
    )
    let store = SmoothScrollConfigurationStore(initial)

    store.replace(with: updated)

    #expect(store.snapshot().gain == 3)
    #expect(store.snapshot().minStep == 16)
}

@Test("连续像素滚轮保持原始事件，只有离散滚轮进入平滑动画")
func smoothScrollInputPolicyKeepsContinuousMouseInputNative() {
    #expect(!SmoothScrollInputPolicy.shouldAnimate(isTrackpad: false, isContinuous: true))
    #expect(!SmoothScrollInputPolicy.shouldAnimate(isTrackpad: true, isContinuous: false))
    #expect(SmoothScrollInputPolicy.shouldAnimate(isTrackpad: false, isContinuous: false))
}
