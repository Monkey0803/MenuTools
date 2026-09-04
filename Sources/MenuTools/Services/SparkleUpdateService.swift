import AppKit
import Sparkle

enum AppUpdateVersionRelationship: Equatable {
    case developmentVersion
    case currentRelease
    case updateAvailable

    static func resolve(current: String, latestPublished: String) -> Self {
        switch current.compare(latestPublished, options: [.numeric, .caseInsensitive]) {
        case .orderedDescending:
            .developmentVersion
        case .orderedAscending:
            .updateAvailable
        case .orderedSame:
            .currentRelease
        }
    }
}

/// 在开发版本高于公开发布版本时，避免 Sparkle 把较旧的发布版本描述为“当前最新版”。
@MainActor
private final class MenuToolsUpdateUserDriver: SPUStandardUserDriver {
    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // 菜单栏入口的检查通常很快，等待完成后直接显示结果。
        // 不创建 Sparkle 的中间进度窗口，避免结果提示与进度窗口叠在一起。
    }

    override func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        guard let versions = developmentVersionInfo(from: error) else {
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            return
        }

        showDevelopmentVersionAlert(current: versions.current, latestPublished: versions.latestPublished)
        acknowledgement()
    }

    private func developmentVersionInfo(
        from error: any Error
    ) -> (current: String, latestPublished: String)? {
        let nsError = error as NSError
        guard let latestItem = nsError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem else {
            return nil
        }

        let current = AppVersionService.current
        let latestPublished = latestItem.displayVersionString
        guard AppUpdateVersionRelationship.resolve(
            current: current,
            latestPublished: latestPublished
        ) == .developmentVersion else {
            return nil
        }

        return (current, latestPublished)
    }

    private func showDevelopmentVersionAlert(current: String, latestPublished: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = L("update.developmentVersion.title")
        alert.informativeText = L("update.developmentVersion.message", current, latestPublished)
        alert.addButton(withTitle: L("update.developmentVersion.confirm"))
        alert.runModal()
    }
}

/// Sparkle 更新入口。
///
/// 更新检查、下载、签名校验、安装和重启全部交给 Sparkle，界面只负责触发
/// `checkForUpdates()`。这样不会再出现自定义下载器与更新安装流程不一致的问题。
@MainActor
final class SparkleUpdateService {
    static let shared = SparkleUpdateService()

    private let userDriver: MenuToolsUpdateUserDriver
    private let updater: SPUUpdater

    private init() {
        let userDriver = MenuToolsUpdateUserDriver(hostBundle: .main, delegate: nil)
        self.userDriver = userDriver
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: nil
        )

        // 让现有设置键继续生效，同时由 Sparkle 自己持久化其内部偏好。
        // 不在 Info.plist 中强制覆盖用户已经做出的选择。
        let automaticChecks = UserDefaults.standard.object(forKey: SettingsKey.autoCheckUpdate) as? Bool ?? true
        updater.automaticallyChecksForUpdates = automaticChecks

        do {
            try updater.start()
        } catch {
            NSLog("Sparkle updater 启动失败：%@", error.localizedDescription)
        }
    }

    /// 手动检查时显示 Sparkle 标准更新窗口。
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// 设置页开关改变时同步到 Sparkle。
    func setAutomaticChecksEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: SettingsKey.autoCheckUpdate)
        updater.automaticallyChecksForUpdates = enabled
    }

    var canCheckForUpdates: Bool {
        updater.canCheckForUpdates
    }
}
