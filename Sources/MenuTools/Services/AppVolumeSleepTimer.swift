import Foundation

/// 睡眠定时：倒数到 0 前最后一段时间线性淡出，然后静音。
///
/// 纯状态机，便于注入时间回归；界面与定时任务只负责驱动。
struct AppVolumeSleepTimer: Equatable, Sendable {
    /// 最后 30 秒用于淡出。
    static let fadeDuration: TimeInterval = 30
    static let minuteOptions = [15, 30, 45, 60, 90, 120]

    var startedAt: Date
    var duration: TimeInterval
    /// 开始时的主音量，用于淡出与取消时恢复。
    var baseVolume: Double

    var endsAt: Date {
        startedAt.addingTimeInterval(duration)
    }

    func remaining(at now: Date) -> TimeInterval {
        max(endsAt.timeIntervalSince(now), 0)
    }

    func isExpired(at now: Date) -> Bool {
        now >= endsAt
    }

    /// 相对原音量的缩放：正常阶段为 1，最后 30 秒线性降到 0。
    func gainScale(at now: Date) -> Double {
        let remaining = remaining(at: now)
        guard remaining > 0 else { return 0 }
        guard remaining < Self.fadeDuration else { return 1 }
        return remaining / Self.fadeDuration
    }

    /// 当前应该设置的主音量。
    func volume(at now: Date) -> Double {
        let value = baseVolume * gainScale(at: now)
        return min(max(value.isFinite ? value : 0, 0), 1)
    }

    /// 剩余分钟数（向上取整，界面显示用）。
    func remainingMinutes(at now: Date) -> Int {
        Int(ceil(remaining(at: now) / 60))
    }
}
