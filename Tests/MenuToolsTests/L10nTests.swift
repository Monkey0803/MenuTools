import Foundation
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

@Test("剪贴板引用的文案在全部五种语言里都存在")
func clipboardLocalizationCoversEveryReferencedKey() throws {
    let referencedKeys = try LocalizationAudit.referencedKeys(repositoryRoot: LocalizationAudit.repositoryRoot)
        .filter { $0.hasPrefix("clipboard.") }
    #expect(!referencedKeys.isEmpty)

    let locales = try LocalizationAudit.localeFiles(repositoryRoot: LocalizationAudit.repositoryRoot)
    #expect(locales.count == 5)

    for locale in locales {
        let entries = try LocalizationAudit.entries(at: locale.url)
        // 取值为 key 本身说明运行时会直接把 key 显示给用户。
        let missing = referencedKeys.subtracting(entries.keys).sorted()
        #expect(missing.isEmpty, "\(locale.name) 缺少剪贴板文案：\(missing)")
    }
}

@Test("代码引用的全部文案在五种语言里都存在")
func localizationCoversEveryReferencedKey() throws {
    let referencedKeys = try LocalizationAudit.referencedKeys(repositoryRoot: LocalizationAudit.repositoryRoot)
    #expect(referencedKeys.count > 500)

    let locales = try LocalizationAudit.localeFiles(repositoryRoot: LocalizationAudit.repositoryRoot)
    #expect(locales.count == 5)

    for locale in locales {
        let entries = try LocalizationAudit.entries(at: locale.url)
        let missing = referencedKeys.subtracting(entries.keys).sorted()
        #expect(missing.isEmpty, "\(locale.name) 缺少文案：\(missing)")
    }
}

@Test("全部语言的本地化文件都不含重复键")
func localizationFilesHaveNoDuplicateKeys() throws {
    let locales = try LocalizationAudit.localeFiles(repositoryRoot: LocalizationAudit.repositoryRoot)
    #expect(locales.count == 5)

    for locale in locales {
        let duplicates = try LocalizationAudit.duplicateKeys(at: locale.url)
        #expect(duplicates.isEmpty, "\(locale.name) 存在重复键：\(duplicates)")
    }
}

/// 从仓库源码里收集本地化键，避免“代码新增文案但漏了某个 lproj”再次发生。
enum LocalizationAudit {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    struct LocaleFile {
        let name: String
        let url: URL
    }

    /// 代码直接引用的字面量键 + 通过枚举拼接的动态键族。
    static func referencedKeys(repositoryRoot: URL) throws -> Set<String> {
        var keys = try literalKeys(repositoryRoot: repositoryRoot)
        keys.formUnion(dynamicKeys)
        return keys
    }

    static func literalKeys(repositoryRoot: URL) throws -> Set<String> {
        let sourcesRoot = repositoryRoot.appendingPathComponent("Sources")
        let expression = try NSRegularExpression(pattern: #"L\(\s*"([^"]+)""#)
        var keys = Set<String>()
        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex ..< source.endIndex, in: source)
            for match in expression.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[keyRange])
                // 带插值的拼接键交给 dynamicKeys 展开，正则只负责字面量。
                guard !key.contains(#"\("#) else { continue }
                keys.insert(key)
            }
        }
        return keys
    }

    /// `localizationKey` / `titleKey` 这类拼接出来的键，必须逐个枚举，正则扫不到。
    /// 新增枚举或枚举 case 时这里要同步补上，否则对应文案的缺失不会被发现。
    private static var dynamicKeys: Set<String> {
        var keys = Set<String>()
        // 剪贴板
        keys.formUnion(ClipboardHistoryCategory.allCases.map(\.titleKey))
        keys.formUnion(ClipboardHistorySortOrder.allCases.map(\.titleKey))
        keys.formUnion(ClipboardHistoryDateFilter.allCases.map(\.titleKey))
        keys.formUnion(ClipboardPrimaryAction.allCases.map(\.localizationKey))
        keys.formUnion(ClipboardSequentialPasteMode.allCases.map(\.localizationKey))
        keys.formUnion(ClipboardTextTransform.allCases.map(\.localizationKey))
        keys.formUnion(ClipboardHistorySettingsTab.allCases.map(\.titleKey))
        keys.formUnion(ClipboardCopyFeedback.allCases.map(\.localizationKey))
        keys.formUnion(ClipboardShortcutRegistrationMode.allCases.map(\.localizationKey))
        // 功能中心
        keys.formUnion(BuiltInPluginID.allCases.flatMap {
            ["plugin.\($0.rawValue).title", "plugin.\($0.rawValue).description"]
        })
        keys.formUnion(BuiltInPluginCategory.allCases.map { "plugin.category.\($0.rawValue)" })
        keys.formUnion(BuiltInPluginPermission.allCases.map { "plugin.permission.\($0.rawValue)" })
        keys.formUnion(PluginCenterFilter.allCases.map(\.titleKey))
        // 快捷操作与右键菜单
        keys.formUnion(QuickAction.allCases.map(\.titleKey))
        keys.formUnion(RightClickItem.allCases.map(\.titleKey))
        keys.formUnion(RightClickItem.allCases.compactMap(\.subtitleKey))
        keys.formUnion(RightClickItem.Group.allCases.map(\.titleKey))
        // 场景与窗口
        keys.formUnion(ScenePreset.allCases.map(\.titleKey))
        keys.formUnion(ScenePreset.allCases.map(\.subtitleKey))
        keys.formUnion(WindowLayout.allCases.map(\.titleKey))
        // 截图
        keys.formUnion(ScreenshotCaptureMode.allCases.map(\.titleKey))
        keys.formUnion(ScreenshotCaptureMode.allCases.map { "screenshot.shortcut.desc.\($0.rawValue)" })
        keys.formUnion(ScreenshotLongCapturePhase.allCases.map(\.titleKey))
        keys.formUnion(ScreenshotOutputFormat.allCases.map(\.titleKey))
        keys.formUnion(ScreenshotEditorTool.allCases.map(\.titleKey))
        keys.formUnion(ScreenshotEditorColor.allCases.map(\.titleKey))
        // 存储与网络流量（NetworkTrafficSection 是 private，这里显式列出；新增 tab 需同步）
        keys.formUnion(StorageCategory.allCases.map(\.titleKey))
        keys.formUnion(["overview", "apps", "history", "diagnostics"].map { "traffic.tab.\($0)" })
        // App 音量
        keys.formUnion(AppVolumeEqualizerPreset.allCases.map(\.titleKey))
        keys.formUnion(AppVolumeSessionFilter.allCases.map { "volume.filter.\($0.rawValue)" })
        keys.formUnion(AppVolumeAppGroup.allCases.map(\.titleKey))
        keys.formUnion(AppVolumeSessionSort.allCases.map(\.titleKey))
        return keys
    }

    static func localeFiles(repositoryRoot: URL) throws -> [LocaleFile] {
        let resources = repositoryRoot.appendingPathComponent("Resources")
        return try FileManager.default
            .contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                LocaleFile(
                    name: url.lastPathComponent,
                    url: url.appendingPathComponent("Localizable.strings")
                )
            }
    }

    static func entries(at url: URL) throws -> [String: String] {
        let source = try String(contentsOf: url, encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*=\s*"((?:[^"\\]|\\.)*)";"#)
        var entries: [String: String] = [:]
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: range),
                  let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else {
                continue
            }
            entries[String(text[keyRange])] = String(text[valueRange])
        }
        return entries
    }

    /// 重复键会让取值依赖行序（实际是后者覆盖前者），必须报出来。
    static func duplicateKeys(at url: URL) throws -> [String] {
        let source = try String(contentsOf: url, encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*="#)
        var seen = Set<String>()
        var duplicates = Set<String>()
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: range),
                  let keyRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let key = String(text[keyRange])
            if !seen.insert(key).inserted {
                duplicates.insert(key)
            }
        }
        return duplicates.sorted()
    }
}
