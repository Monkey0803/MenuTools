import Foundation

/// 平滑滚动配置（从 UserDefaults 读取，UI 用 @AppStorage 写入同一批 Key）
struct ScrollConfig {
    var enabled: Bool
    var smoothVertical: Bool
    var smoothHorizontal: Bool
    var invertVertical: Bool
    var invertHorizontal: Bool
    var gain: Double       // 速度增益 0.5 ~ 3.0
    var duration: Double   // 持续时间（秒）0.1 ~ 0.8
    var minStep: Double    // 最短步长（像素）
    var touchpadEmulation: Bool
    var accelModifier: UInt   // 加速键（NSEvent.ModifierFlags rawValue，0=未设）
    var shiftModifier: UInt   // 转换键（垂直→水平）
    var disableModifier: UInt // 禁用键

    static func load() -> ScrollConfig {
        let d = UserDefaults.standard
        func dbl(_ key: String, _ fallback: Double) -> Double {
            d.object(forKey: key) == nil ? fallback : d.double(forKey: key)
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            d.object(forKey: key) == nil ? fallback : d.bool(forKey: key)
        }
        func uint(_ key: String) -> UInt {
            UInt(bitPattern: d.integer(forKey: key))
        }
        return ScrollConfig(
            enabled: bool(SettingsKey.scrollEnabled, false),
            smoothVertical: bool(SettingsKey.scrollSmoothV, true),
            smoothHorizontal: bool(SettingsKey.scrollSmoothH, true),
            invertVertical: bool(SettingsKey.scrollInvertV, false),
            invertHorizontal: bool(SettingsKey.scrollInvertH, false),
            gain: dbl(SettingsKey.scrollGain, 1.0),
            duration: dbl(SettingsKey.scrollDuration, 0.35),
            minStep: dbl(SettingsKey.scrollMinStep, 8),
            touchpadEmulation: bool(SettingsKey.scrollTouchpad, true),
            accelModifier: uint(SettingsKey.scrollAccelKey),
            shiftModifier: uint(SettingsKey.scrollShiftKey),
            disableModifier: uint(SettingsKey.scrollDisableKey)
        )
    }
}
