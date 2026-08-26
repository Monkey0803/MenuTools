import Foundation
import Sparkle

/// Sparkle 更新入口。
///
/// 更新检查、下载、签名校验、安装和重启全部交给 Sparkle，界面只负责触发
/// `checkForUpdates()`。这样不会再出现自定义下载器与更新安装流程不一致的问题。
@MainActor
final class SparkleUpdateService {
    static let shared = SparkleUpdateService()

    let updaterController: SPUStandardUpdaterController

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // 让现有设置键继续生效，同时由 Sparkle 自己持久化其内部偏好。
        // 不在 Info.plist 中强制覆盖用户已经做出的选择。
        let automaticChecks = UserDefaults.standard.object(forKey: SettingsKey.autoCheckUpdate) as? Bool ?? true
        updaterController.updater.automaticallyChecksForUpdates = automaticChecks
        updaterController.startUpdater()
    }

    /// 手动检查时显示 Sparkle 标准更新窗口。
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// 设置页开关改变时同步到 Sparkle。
    func setAutomaticChecksEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: SettingsKey.autoCheckUpdate)
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }
}
