import Foundation

/// 备份文件当前支持的配置快照。
struct AppBackupSettings: Codable, Equatable, Sendable {
    var menuBarIcon: String
    var menuBarShowTitle: Bool
    var togglesShowTitle: Bool
    var preferredTerminal: String
    var autoCheckUpdate: Bool
    var appLanguage: String

    var scrollEnabled: Bool
    var scrollSmoothVertical: Bool
    var scrollSmoothHorizontal: Bool
    var scrollInvertVertical: Bool
    var scrollInvertHorizontal: Bool
    var scrollGain: Double
    var scrollDuration: Double
    var scrollMinStep: Double
    var scrollTouchpadEmulation: Bool
    var scrollAccelModifier: UInt
    var scrollShiftModifier: UInt
    var scrollDisableModifier: UInt

    /// v1 后增补的可选字段；缺失时代表旧备份，不覆盖当前音量配置。
    var appVolumeEnabled: Bool? = nil
    var appVolumeProfiles: [String: AppVolumeProfile]? = nil

    /// v1.1.0 增补的可选字段；旧备份缺失时不覆盖当前插件选择。
    var enabledPluginIDs: [String]? = nil
    var pluginOrder: [String]? = nil

    /// 网络流量设置；旧备份缺失时保留当前配置。
    var networkTrafficQuery: String? = nil
    var networkTrafficAlertThreshold: Int64? = nil
    var networkTrafficMenuBarDisplayMode: String? = nil
    var networkTrafficMonthlyQuota: Int64? = nil
}

/// 备份文档校验失败的原因。
enum AppBackupValidationError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case invalidMenuBarIcon(String)
    case invalidPreferredTerminal(String)
    case invalidAppLanguage(String)
    case invalidGain(Double)
    case invalidDuration(Double)
    case invalidMinimumStep(Double)
    case invalidModifier(String, UInt)
    case invalidAppVolume(String, Double)
    case invalidRightClickKey(String)
    case invalidPluginConfiguration
    case invalidNetworkTrafficQuery(String)
    case invalidNetworkTrafficThreshold(Int64)
    case invalidNetworkTrafficMenuBarDisplayMode(String)
    case invalidNetworkTrafficMonthlyQuota(Int64)
}

/// MenuTools 配置备份文档。
struct AppBackupDocument: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var createdAt: Date
    var appVersion: String
    var settings: AppBackupSettings
    var rightClick: RightClickConfig

    /// 创建当前版本的备份文档。
    static func current(
        settings: AppBackupSettings,
        rightClick: RightClickConfig,
        appVersion: String,
        createdAt: Date
    ) -> AppBackupDocument {
        AppBackupDocument(
            formatVersion: currentFormatVersion,
            createdAt: createdAt,
            appVersion: appVersion,
            settings: settings,
            rightClick: rightClick
        )
    }

    /// 校验版本、允许值、平滑滚动数值和修饰键，返回可安全恢复的文档。
    func validated() throws -> AppBackupDocument {
        guard formatVersion == Self.currentFormatVersion else {
            throw AppBackupValidationError.unsupportedFormatVersion(formatVersion)
        }

        guard MenuBarIcon(rawValue: settings.menuBarIcon) != nil else {
            throw AppBackupValidationError.invalidMenuBarIcon(settings.menuBarIcon)
        }
        guard TerminalApp(rawValue: settings.preferredTerminal) != nil else {
            throw AppBackupValidationError.invalidPreferredTerminal(settings.preferredTerminal)
        }
        guard AppLanguage(rawValue: settings.appLanguage) != nil else {
            throw AppBackupValidationError.invalidAppLanguage(settings.appLanguage)
        }

        guard settings.scrollGain.isFinite, (0.1...10.0).contains(settings.scrollGain) else {
            throw AppBackupValidationError.invalidGain(settings.scrollGain)
        }
        guard settings.scrollDuration.isFinite, (0.05...2.0).contains(settings.scrollDuration) else {
            throw AppBackupValidationError.invalidDuration(settings.scrollDuration)
        }
        guard settings.scrollMinStep.isFinite, (1.0...100.0).contains(settings.scrollMinStep) else {
            throw AppBackupValidationError.invalidMinimumStep(settings.scrollMinStep)
        }

        for (name, value) in [
            ("scrollAccelModifier", settings.scrollAccelModifier),
            ("scrollShiftModifier", settings.scrollShiftModifier),
            ("scrollDisableModifier", settings.scrollDisableModifier)
        ] where value & ~Self.allowedModifierMask != 0 {
            throw AppBackupValidationError.invalidModifier(name, value)
        }

        for (identifier, profile) in settings.appVolumeProfiles ?? [:] {
            guard profile.volume.isFinite, (0...1).contains(profile.volume) else {
                throw AppBackupValidationError.invalidAppVolume(identifier, profile.volume)
            }
            guard profile.lastNonzeroVolume.isFinite,
                  (0...1).contains(profile.lastNonzeroVolume) else {
                throw AppBackupValidationError.invalidAppVolume(identifier, profile.lastNonzeroVolume)
            }
        }

        for key in rightClick.enabled.keys.sorted() where RightClickItem(rawValue: key) == nil {
            throw AppBackupValidationError.invalidRightClickKey(key)
        }


        switch (settings.enabledPluginIDs, settings.pluginOrder) {
        case (nil, nil):
            break
        case let (enabled?, order?):
            let enabledIDs = enabled.compactMap(BuiltInPluginID.init(rawValue:))
            let orderedIDs = order.compactMap(BuiltInPluginID.init(rawValue:))
            guard enabledIDs.count == enabled.count,
                  orderedIDs.count == order.count,
                  (try? BuiltInPluginConfiguration(
                    enabledPluginIDs: enabledIDs,
                    orderedPluginIDs: orderedIDs
                  ).validated()) != nil else {
                throw AppBackupValidationError.invalidPluginConfiguration
            }
        default:
            throw AppBackupValidationError.invalidPluginConfiguration
        }

        if let query = settings.networkTrafficQuery,
           NetworkTrafficQuery(storageKey: query) == nil {
            throw AppBackupValidationError.invalidNetworkTrafficQuery(query)
        }
        if let threshold = settings.networkTrafficAlertThreshold,
           !(0...1_000_000_000).contains(threshold) {
            throw AppBackupValidationError.invalidNetworkTrafficThreshold(threshold)
        }
        if let mode = settings.networkTrafficMenuBarDisplayMode,
           NetworkTrafficMenuBarDisplayMode(rawValue: mode) == nil {
            throw AppBackupValidationError.invalidNetworkTrafficMenuBarDisplayMode(mode)
        }
        if let quota = settings.networkTrafficMonthlyQuota,
           !(0...10_000_000_000_000_000).contains(quota) {
            throw AppBackupValidationError.invalidNetworkTrafficMonthlyQuota(quota)
        }

        return self
    }

    private static let allowedModifierMask: UInt =
        (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
}
