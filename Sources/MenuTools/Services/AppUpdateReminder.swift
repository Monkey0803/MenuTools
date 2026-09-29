import Foundation
import Observation

/// 后台检查到新版本时的「温和提醒」状态。
///
/// MenuTools 是 `LSUIElement`（无 Dock 图标、无常规窗口），Sparkle 的更新弹窗
/// 容易被用户错过。这里改为：后台检查到的更新只记下来，由界面显示一个不打扰的入口；
/// 用户点它时才让 Sparkle 弹出正式更新窗口。
@MainActor
@Observable
final class AppUpdateReminder {
    static let shared = AppUpdateReminder(defaults: .standard)

    private struct StoredReminder: Codable {
        var version: String
        var notes: String?
    }

    private static let storageKey = "appUpdate.pendingReminder"
    @ObservationIgnored private let defaults: UserDefaults?

    /// 后台发现、还没被用户处理的新版本号。
    private(set) var availableVersion: String?
    /// 该版本的简短说明（来自 appcast 的 description，可能为空）。
    private(set) var availableNotes: String?

    var hasUnseenUpdate: Bool { availableVersion != nil }

    /// 测试默认不使用真实偏好；共享实例才持久化到应用偏好。
    init(defaults: UserDefaults? = nil, currentVersion: String = AppVersionService.current) {
        self.defaults = defaults
        guard let defaults,
              let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(StoredReminder.self, from: data) else { return }

        if stored.version.compare(currentVersion, options: [.numeric, .caseInsensitive]) == .orderedDescending {
            availableVersion = stored.version
            availableNotes = stored.notes
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    /// 后台检查到新版本时记录；同一版本重复记录不会有副作用。
    func noteAvailable(version: String, notes: String? = nil) {
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else { return }
        availableVersion = trimmedVersion
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        availableNotes = (trimmedNotes?.isEmpty ?? true) ? nil : trimmedNotes
        if let data = try? JSONEncoder().encode(StoredReminder(version: trimmedVersion, notes: availableNotes)) {
            defaults?.set(data, forKey: Self.storageKey)
        }
    }

    /// 用户已经看到正式更新提示（或本轮更新会话结束）时收起提醒。
    func acknowledge() {
        availableVersion = nil
        availableNotes = nil
        defaults?.removeObject(forKey: Self.storageKey)
    }
}
