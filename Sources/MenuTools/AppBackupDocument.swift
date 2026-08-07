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
}

/// 备份文档校验失败的原因。
enum AppBackupValidationError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case invalidGain(Double)
    case invalidDuration(Double)
    case invalidMinimumStep(Double)
    case invalidModifier(String, UInt)
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

    /// 校验版本、平滑滚动数值和修饰键，返回可安全恢复的文档。
    func validated() throws -> AppBackupDocument {
        guard formatVersion == Self.currentFormatVersion else {
            throw AppBackupValidationError.unsupportedFormatVersion(formatVersion)
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

        return self
    }

    private static let allowedModifierMask: UInt =
        (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
}
