import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MenuTools

@Test("翻译请求会清理首尾空白并保留正文")
func translationRequestNormalizesInput() throws {
    let request = try TranslationRequest(
        text: "  Hello, world!  \n",
        targetLanguage: .simplifiedChinese
    )

    #expect(request.text == "Hello, world!")
    #expect(request.targetLanguage == .simplifiedChinese)
}

@Test("空白剪贴板内容不可发起翻译")
func translationRequestRejectsEmptyInput() {
    #expect(throws: TranslationError.emptyInput) {
        _ = try TranslationRequest(text: " \n\t ", targetLanguage: .english)
    }
}

@Test("AI 接口必须使用 HTTPS 以保护 API Key")
func translationConfigurationRejectsInsecureEndpoint() {
    #expect(throws: TranslationError.invalidEndpoint) {
        _ = try TranslationAIConfiguration(
            endpoint: "http://localhost:11434/v1/chat/completions",
            model: "test-model",
            apiKey: "test-key"
        )
    }
}

@Test("OpenRouter API 根地址会补全为聊天补全端点")
func translationConfigurationNormalizesOpenRouterAPIBase() throws {
    let configuration = try TranslationAIConfiguration(
        endpoint: "https://openrouter.ai/api",
        model: "anthropic/claude-4.6-opus",
        apiKey: "test-key"
    )

    #expect(configuration.endpoint.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
}

@Test("完整聊天补全地址不会重复追加路径")
func translationConfigurationPreservesChatCompletionsEndpoint() throws {
    let endpoint = "https://openrouter.ai/api/v1/chat/completions"
    let configuration = try TranslationAIConfiguration(
        endpoint: endpoint,
        model: "anthropic/claude-4.6-opus",
        apiKey: "test-key"
    )

    #expect(configuration.endpoint.absoluteString == endpoint)
}

@Test("完整聊天补全地址会移除末尾斜杠")
func translationConfigurationNormalizesTrailingSlash() throws {
    let configuration = try TranslationAIConfiguration(
        endpoint: "https://openrouter.ai/api/v1/chat/completions/",
        model: "test-model",
        apiKey: "test-key"
    )

    #expect(configuration.endpoint.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
}

@Test("OpenRouter 的旧 Claude 模型名会迁移为当前规范 ID")
func translationConfigurationNormalizesOpenRouterClaudeModel() throws {
    let configuration = try TranslationAIConfiguration(
        endpoint: "https://openrouter.ai/api",
        model: "anthropic/claude-4.6-opus",
        apiKey: "test-key"
    )

    #expect(configuration.model == "anthropic/claude-opus-4.6")
}

@Test("OpenAI 兼容请求带上目标语言与原文")
func openAICompatibleRequestBuildsExpectedMessages() throws {
    let request = try TranslationRequest(text: "Good morning", targetLanguage: .japanese)
    let payload = OpenAICompatibleTranslationPayload(request: request, model: "test-model")

    #expect(payload.model == "test-model")
    #expect(payload.messages.count == 2)
    #expect(payload.messages[0].content.contains("日语"))
    #expect(payload.messages[1].content == "Good morning")
    #expect(payload.temperature == 0.2)
}

@Test("OpenAI 兼容响应提取首个有效译文")
func openAICompatibleResponseExtractsTranslation() throws {
    let data = try #require("""
    {"choices":[{"message":{"content":"早上好"}}]}
    """.data(using: .utf8))

    #expect(try OpenAICompatibleTranslationResponse.translation(from: data) == "早上好")
}

@Test("空的 AI 响应会报告无译文错误")
func openAICompatibleResponseRejectsEmptyTranslation() throws {
    let data = try #require("""
    {"choices":[{"message":{"content":"  "}}]}
    """.data(using: .utf8))

    #expect(throws: TranslationError.emptyResponse) {
        _ = try OpenAICompatibleTranslationResponse.translation(from: data)
    }
}

@Test("API Key 缓存避免重复访问钥匙串")
func translationAPIKeyCacheAvoidsRepeatedKeychainReads() {
    var cache = TranslationAPIKeyCache()
    var readCount = 0

    #expect(cache.load {
        readCount += 1
        return "test-key"
    } == "test-key")
    #expect(cache.load {
        readCount += 1
        return "other-key"
    } == "test-key")
    #expect(readCount == 1)

    cache.store("updated-key")
    #expect(cache.load { nil } == "updated-key")

    cache.clear()
    #expect(cache.load { nil } == nil)
}

@Test("API Key 读取失败后不会重复访问钥匙串")
func translationAPIKeyCacheRemembersFailedRead() {
    var cache = TranslationAPIKeyCache()
    var readCount = 0

    #expect(cache.load {
        readCount += 1
        return nil
    } == nil)
    #expect(cache.load {
        readCount += 1
        return "unexpected-key"
    } == nil)
    #expect(readCount == 1)
}

@Test("清除过期 API Key 后不会复用旧缓存")
func translationAPIKeyCacheDoesNotReuseClearedValue() {
    var cache = TranslationAPIKeyCache()
    cache.store("expired-key")
    cache.clear()

    #expect(cache.load { "unexpected-key" } == nil)
}

@Test("翻译快捷键会持久化且可清除")
@MainActor
func translationShortcutPersistsAndClearsBinding() throws {
    let suiteName = "MenuTools-TranslationShortcutTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    let shortcut = GlobalShortcut(keyCode: 17, modifiers: GlobalShortcutModifier.controlOption)
    let service = TranslationShortcutService(
        defaults: defaults,
        conflictChecker: TranslationShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        clipboardBindingProvider: { nil },
        appVolumeBindingProvider: { nil },
        onTrigger: {}
    )

    try service.setBinding(shortcut)
    #expect(service.binding == shortcut)

    let restored = TranslationShortcutService(
        defaults: defaults,
        conflictChecker: TranslationShortcutConflictChecker(),
        sceneBindingsProvider: { [:] },
        windowBindingsProvider: { [:] },
        appBindingsProvider: { [:] },
        screenshotBindingsProvider: { [:] },
        clipboardBindingProvider: { nil },
        appVolumeBindingProvider: { nil },
        onTrigger: {}
    )
    #expect(restored.binding == shortcut)

    restored.clearBinding()
    #expect(restored.binding == nil)
}

@MainActor
private struct TranslationShortcutConflictChecker: ShortcutConflictChecking {
    func conflict(
        for shortcut: GlobalShortcut,
        context: ShortcutConflictContext
    ) -> ShortcutConflictSource? {
        nil
    }
}

@Test("启用翻译插件后主面板显示翻译入口")
func translationPanelEntryFollowsPluginState() {
    #expect(TranslationPanelEntryPolicy.shouldShow(isPluginEnabled: true))
    #expect(!TranslationPanelEntryPolicy.shouldShow(isPluginEnabled: false))
}

@Test("功能设置页可以返回功能总览")
func featureSettingsHavePluginsParent() {
    #expect(SettingsNavigationPolicy.parent(for: .translation) == .plugins)
    #expect(SettingsNavigationPolicy.parent(for: .clipboard) == .plugins)
    #expect(SettingsNavigationPolicy.parent(for: .plugins) == nil)
}

@Test("空白配置使用默认值，以便界面显示 placeholder")
func translationSettingsUseDefaultsForBlankValues() {
    #expect(
        TranslationSettingsValue.resolved("  ", fallback: TranslationSettingsKey.defaultEndpoint)
            == TranslationSettingsKey.defaultEndpoint
    )
    #expect(
        TranslationSettingsValue.resolved("custom-model", fallback: TranslationSettingsKey.defaultModel)
            == "custom-model"
    )
}

@Test("已存储的默认配置会迁移为空值以显示 placeholder")
func storedTranslationDefaultsMigrateToPlaceholder() {
    #expect(
        TranslationSettingsValue.placeholderValue(
            TranslationSettingsKey.defaultEndpoint,
            placeholder: TranslationSettingsKey.defaultEndpoint
        ).isEmpty
    )
    #expect(
        TranslationSettingsValue.placeholderValue("custom-model", placeholder: TranslationSettingsKey.defaultModel)
            == "custom-model"
    )
}

@Test("只读译文框仍支持选择和鼠标滚动")
@MainActor
func readOnlyTranslationEditorRemainsInteractive() throws {
    let configuration = TranslationTextEditorConfiguration(isEditable: false)
    let scrollView = TranslationTextEditor.makeScrollView(
        text: Array(repeating: "这是一段用于验证长译文滚动行为的文本。", count: 80).joined(separator: "\n"),
        configuration: configuration,
        delegate: nil
    )
    let textView = try #require(scrollView.documentView as? NSTextView)
    scrollView.frame = NSRect(x: 0, y: 0, width: 280, height: 100)
    textView.frame.size.width = scrollView.contentSize.width
    textView.sizeToFit()

    let visibleHeight = scrollView.contentView.bounds.height
    let targetOrigin = NSPoint(x: 0, y: textView.frame.height - visibleHeight)
    scrollView.contentView.scroll(to: targetOrigin)

    #expect(!configuration.isEditable)
    #expect(!textView.isEditable)
    #expect(textView.isSelectable)
    #expect(scrollView.hasVerticalScroller)
    #expect(textView.autoresizingMask.contains(.width))
    #expect(textView.frame.height > visibleHeight)
    #expect(scrollView.contentView.bounds.origin.y > 0)
}

@Test("原文编辑会更新绑定，译文不会更新绑定")
@MainActor
func translationTextEditorUpdatesOnlyEditableBinding() throws {
    var sourceText = "原文"
    let sourceEditor = TranslationTextEditor(
        text: Binding(get: { sourceText }, set: { sourceText = $0 }),
        isEditable: true
    )
    let sourceCoordinator = sourceEditor.makeCoordinator()
    let sourceScrollView = TranslationTextEditor.makeScrollView(
        text: sourceText,
        configuration: sourceEditor.configuration,
        delegate: sourceCoordinator
    )
    let sourceTextView = try #require(sourceScrollView.documentView as? NSTextView)
    sourceTextView.string = "修改后的原文"
    sourceCoordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: sourceTextView))
    #expect(sourceText == "修改后的原文")

    var translatedText = "译文"
    let resultEditor = TranslationTextEditor(
        text: Binding(get: { translatedText }, set: { translatedText = $0 }),
        isEditable: false
    )
    let resultCoordinator = resultEditor.makeCoordinator()
    let resultScrollView = TranslationTextEditor.makeScrollView(
        text: translatedText,
        configuration: resultEditor.configuration,
        delegate: resultCoordinator
    )
    let resultTextView = try #require(resultScrollView.documentView as? NSTextView)
    resultTextView.string = "不应写回的译文"
    resultCoordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: resultTextView))
    #expect(translatedText == "译文")
}

@Test("翻译窗口按 Escape 会请求关闭")
@MainActor
func translationWindowEscapeRequestsDismissal() throws {
    var dismissalRequests = 0
    let panel = TranslationWindowPanel(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    panel.onDismissRequest = { dismissalRequests += 1 }
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: "\u{1B}",
        charactersIgnoringModifiers: "\u{1B}",
        isARepeat: false,
        keyCode: 53
    ))

    panel.sendEvent(event)

    #expect(dismissalRequests == 1)
}

@Test("翻译窗口失去焦点会请求关闭")
@MainActor
func translationWindowResigningKeyRequestsDismissal() {
    var dismissalRequests = 0
    let panel = TranslationWindowPanel(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    panel.onDismissRequest = { dismissalRequests += 1 }

    panel.resignKey()

    #expect(dismissalRequests == 1)
}

@Test("重新唤起翻译窗口时会清除已取消任务的加载状态")
@MainActor
func translationPresentationClearsPreviousLoadingState() {
    let model = TranslationWindowModel(clipboardTextProvider: { "  " })
    model.isTranslating = true

    model.prepareForPresentation()

    #expect(!model.isTranslating)
    #expect(model.errorMessage == TranslationError.emptyInput.localizedDescription)
}

@Test("剪贴板历史可以把指定文本直接交给翻译窗口")
@MainActor
func translationPresentationAcceptsExplicitText() async throws {
    let configuration = try TranslationAIConfiguration(
        endpoint: "https://example.com/v1/chat/completions",
        model: "test-model",
        apiKey: "test-key"
    )
    let model = TranslationWindowModel(
        clipboardTextProvider: { "不应使用剪贴板" },
        configurationProvider: { configuration },
        translationExecutor: { request, _ in request.text }
    )

    model.prepareForPresentation(text: "来自历史的文本")
    for _ in 0 ..< 10 { await Task.yield() }

    #expect(model.sourceText == "来自历史的文本")
    #expect(model.translatedText == "来自历史的文本")
}

@Test("翻译窗口关闭后可由快捷键再次打开")
@MainActor
func translationWindowDismissesAndReopens() async throws {
    let recorder = TranslationCancellationRecorder()
    let configuration = try TranslationAIConfiguration(
        endpoint: "https://example.com/v1/chat/completions",
        model: "test-model",
        apiKey: "test-key"
    )
    let model = TranslationWindowModel(
        clipboardTextProvider: { "hello" },
        configurationProvider: { configuration },
        translationExecutor: { _, _ in
            try await recorder.translate()
        }
    )
    let controller = TranslationWindowController(model: model)
    defer { controller.close() }

    controller.showFromClipboard()
    let panel = try #require(controller.window)
    #expect(panel.isVisible)
    #expect(model.isTranslating)

    let escapeEvent = try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: panel.windowNumber,
        context: nil,
        characters: "\u{1B}",
        charactersIgnoringModifiers: "\u{1B}",
        isARepeat: false,
        keyCode: 53
    ))
    panel.sendEvent(escapeEvent)
    #expect(!panel.isVisible)
    #expect(!model.isTranslating)
    for _ in 0..<10 { await Task.yield() }
    #expect(await recorder.cancellationCount == 1)

    controller.showFromClipboard()
    #expect(panel.isVisible)
    #expect(model.isTranslating)

    panel.resignKey()
    #expect(!panel.isVisible)
    #expect(!model.isTranslating)
    for _ in 0..<10 { await Task.yield() }
    #expect(await recorder.cancellationCount == 2)
}

private actor TranslationCancellationRecorder {
    private(set) var cancellationCount = 0

    func translate() async throws -> String {
        do {
            try await Task.sleep(for: .seconds(60))
            return "不应完成"
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }
}
