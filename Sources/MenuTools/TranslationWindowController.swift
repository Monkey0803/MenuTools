import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class TranslationWindowModel {
    var sourceText = ""
    var translatedText = ""
    var targetLanguage: TranslationLanguage
    var errorMessage: String?
    var isTranslating = false

    private let clipboardTextProvider: () -> String?
    private let configurationProvider: () throws -> TranslationAIConfiguration
    private let translationExecutor: (TranslationRequest, TranslationAIConfiguration) async throws -> String
    private var translationTask: Task<Void, Never>?

    init(
        userDefaults: UserDefaults = .standard,
        clipboardTextProvider: @escaping () -> String? = {
            NSPasteboard.general.string(forType: .string)
        },
        configurationProvider: @escaping () throws -> TranslationAIConfiguration = {
            try TranslationAIConfiguration(
                endpoint: TranslationSettingsValue.resolved(
                    UserDefaults.standard.string(forKey: TranslationSettingsKey.endpoint),
                    fallback: TranslationSettingsKey.defaultEndpoint
                ),
                model: TranslationSettingsValue.resolved(
                    UserDefaults.standard.string(forKey: TranslationSettingsKey.model),
                    fallback: TranslationSettingsKey.defaultModel
                ),
                apiKey: TranslationAPIKeyStore.load()
            )
        },
        translationExecutor: @escaping (TranslationRequest, TranslationAIConfiguration) async throws -> String = {
            request,
            configuration in
            try await OpenAICompatibleTranslationClient().translate(request, configuration: configuration)
        }
    ) {
        targetLanguage = TranslationLanguage(
            rawValue: userDefaults.string(forKey: TranslationSettingsKey.targetLanguage) ?? ""
        ) ?? .simplifiedChinese
        self.clipboardTextProvider = clipboardTextProvider
        self.configurationProvider = configurationProvider
        self.translationExecutor = translationExecutor
    }

    func prepareForPresentation() {
        prepareForPresentation(text: clipboardTextProvider() ?? "")
    }

    func prepareForPresentation(text: String) {
        cancelTranslation()
        sourceText = text
        translatedText = ""
        errorMessage = nil
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = TranslationError.emptyInput.localizedDescription
            return
        }
        translate()
    }

    func translate() {
        translationTask?.cancel()
        do {
            let request = try TranslationRequest(text: sourceText, targetLanguage: targetLanguage)
            let configuration = try configurationProvider()
            let translationExecutor = translationExecutor
            isTranslating = true
            translatedText = ""
            errorMessage = nil
            translationTask = Task { @MainActor [weak self] in
                do {
                    let translation = try await translationExecutor(request, configuration)
                    guard !Task.isCancelled else { return }
                    self?.translatedText = translation
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.errorMessage = error.localizedDescription
                }
                self?.isTranslating = false
            }
        } catch {
            isTranslating = false
            errorMessage = error.localizedDescription
        }
    }

    func setTargetLanguage(_ language: TranslationLanguage) {
        targetLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: TranslationSettingsKey.targetLanguage)
        if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            translate()
        }
    }

    func copyTranslation() {
        guard !translatedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
    }

    func cancelTranslation() {
        translationTask?.cancel()
        translationTask = nil
        isTranslating = false
    }
}

@MainActor
final class TranslationWindowPanel: NSPanel {
    var onDismissRequest: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onDismissRequest?()
            return
        }

        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onDismissRequest?()
    }
}

/// 独立翻译窗口由控制器持有，确保全局快捷键在菜单栏面板关闭时仍可调出。
@MainActor
final class TranslationWindowController: NSObject, NSWindowDelegate {
    static let shared = TranslationWindowController()

    let model: TranslationWindowModel
    private(set) var window: TranslationWindowPanel?

    init(model: TranslationWindowModel = TranslationWindowModel()) {
        self.model = model
        super.init()
    }

    func showFromClipboard() {
        model.prepareForPresentation()
        presentWindow()
    }

    func show(text: String) {
        model.prepareForPresentation(text: text)
        presentWindow()
    }

    private func presentWindow() {
        let window = makeWindowIfNeeded()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.cancelTranslation()
    }

    func close() {
        dismiss()
    }

    private func dismiss() {
        model.cancelTranslation()
        window?.orderOut(nil)
    }

    private func makeWindowIfNeeded() -> TranslationWindowPanel {
        if let window { return window }
        let panel = TranslationWindowPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = L("translation.windowTitle")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.minSize = NSSize(width: 520, height: 380)
        panel.center()
        panel.delegate = self
        panel.onDismissRequest = { [weak self] in
            self?.dismiss()
        }
        panel.contentViewController = NSHostingController(rootView: TranslationWindowView(model: model))
        window = panel
        return panel
    }
}
