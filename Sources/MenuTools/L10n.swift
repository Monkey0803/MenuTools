import Foundation

/// 应用内语言选择；system = 跟随系统语言
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    /// 语言名用其本身文字展示（业界惯例），仅“跟随系统”随界面语言本地化
    var displayName: String {
        switch self {
        case .system: return L("settings.language.system")
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }
}

enum AppLanguageResolver {
    static func resourceLanguage(
        configuredLanguage: String,
        preferredLanguages: [String]
    ) -> String? {
        if configuredLanguage != AppLanguage.system.rawValue,
           AppLanguage(rawValue: configuredLanguage) != nil {
            return configuredLanguage
        }
        for language in preferredLanguages {
            let normalized = language.lowercased().replacingOccurrences(of: "_", with: "-")
            if normalized.hasPrefix("zh-hans") || normalized.hasPrefix("zh-cn") || normalized.hasPrefix("zh-sg") {
                return AppLanguage.simplifiedChinese.rawValue
            }
            if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw")
                || normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-mo") {
                return AppLanguage.traditionalChinese.rawValue
            }
            if normalized.hasPrefix("en") { return AppLanguage.english.rawValue }
            if normalized.hasPrefix("ja") { return AppLanguage.japanese.rawValue }
            if normalized.hasPrefix("ko") { return AppLanguage.korean.rawValue }
        }
        return nil
    }
}

/// 解析当前生效的本地化 bundle：
/// 用户手动选择语言时取对应 lproj，否则用主 bundle（随系统语言解析）
private func l10nBundle() -> Bundle {
    let raw = UserDefaults.standard.string(forKey: SettingsKey.appLanguage) ?? AppLanguage.system.rawValue
    guard let resourceLanguage = AppLanguageResolver.resourceLanguage(
        configuredLanguage: raw,
        preferredLanguages: Locale.preferredLanguages
    ),
          let path = Bundle.main.path(forResource: resourceLanguage, ofType: "lproj"),
          let bundle = Bundle(path: path) else {
        return .main
    }
    return bundle
}

/// 本地化取值（打包后随系统语言或应用内语言设置解析）
func L(_ key: String) -> String {
    l10nBundle().localizedString(forKey: key, value: nil, table: nil)
}

/// 带格式参数的本地化取值
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: l10nBundle().localizedString(forKey: key, value: nil, table: nil), arguments: args)
}
