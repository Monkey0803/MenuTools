import Testing
@testable import MenuTools

@Test("显示器模式文本包含分辨率和刷新率")
func displayModeLabelContainsResolutionAndRefreshRate() {
    let mode = DisplayModeInfo(width: 2560, height: 1440, refreshRate: 120, isCurrent: true)

    #expect(mode.label == "2560 × 1440 · 120 Hz")
}

@Test("显示器模式无刷新率时不显示伪造数值")
func displayModeLabelOmitsUnknownRefreshRate() {
    let mode = DisplayModeInfo(width: 1920, height: 1080, refreshRate: 0, isCurrent: false)

    #expect(mode.label == "1920 × 1080")
}

@Test("显示器模式去重时优先保留当前模式")
@MainActor
func displayModesPreferCurrentMode() {
    let current = DisplayModeInfo(width: 2560, height: 1440, refreshRate: 120, isCurrent: true)
    let duplicateNonCurrent = DisplayModeInfo(width: 2560, height: 1440, refreshRate: 120, isCurrent: false)

    let modes = DisplayService.uniqueModes([duplicateNonCurrent, current], current: current)

    #expect(modes.count == 1)
    #expect(modes.first?.isCurrent == true)
}
