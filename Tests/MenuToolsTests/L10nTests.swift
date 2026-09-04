import Testing
@testable import MenuTools

@Test("跟随系统语言时会把地区化语言标识解析到现有资源")
func systemLanguageResolvesLocalizedResource() {
    #expect(AppLanguageResolver.resourceLanguage(
        configuredLanguage: "system",
        preferredLanguages: ["zh-Hans-CN"]
    ) == "zh-Hans")
    #expect(AppLanguageResolver.resourceLanguage(
        configuredLanguage: "system",
        preferredLanguages: ["zh-Hant-TW"]
    ) == "zh-Hant")
    #expect(AppLanguageResolver.resourceLanguage(
        configuredLanguage: "system",
        preferredLanguages: ["ja-JP"]
    ) == "ja")
}

@Test("显式应用语言优先于系统语言")
func configuredLanguageOverridesSystemLanguage() {
    #expect(AppLanguageResolver.resourceLanguage(
        configuredLanguage: "ko",
        preferredLanguages: ["zh-Hans-CN"]
    ) == "ko")
}
