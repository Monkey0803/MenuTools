import SwiftUI

struct TranslationSettingsView: View {
    @AppStorage(TranslationSettingsKey.endpoint) private var endpoint = ""
    @AppStorage(TranslationSettingsKey.model) private var model = ""
    @State private var shortcutService = TranslationShortcutService.shared
    @State private var apiKey = ""
    @State private var isRecording = false
    @State private var capturedShortcut: GlobalShortcut?
    @State private var errorMessage: String?
    @State private var didSaveAPIKey = false

    private var displayedShortcut: GlobalShortcut? {
        capturedShortcut ?? shortcutService.binding
    }

    var body: some View {
        Form {
            Section(L("translation.aiSettings")) {
                TextField(
                    L("translation.endpoint"),
                    text: $endpoint,
                    prompt: Text(L("translation.endpointPlaceholder"))
                )
                TextField(
                    L("translation.model"),
                    text: $model,
                    prompt: Text(L("translation.modelPlaceholder"))
                )
                SecureField(L("translation.apiKey"), text: $apiKey)
                HStack {
                    Text(L("translation.apiKeyDescription"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("translation.saveAPIKey"), action: saveAPIKey)
                    if didSaveAPIKey {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Button(L("translation.openWindow"), action: TranslationWindowController.shared.showFromClipboard)
            }

            Section(L("translation.shortcut")) {
                HStack {
                    Text(isRecording ? L("settings.recording") : displayedShortcut?.displayName ?? L("settings.unset"))
                        .font(.callout.monospaced())
                        .foregroundStyle(isRecording || displayedShortcut != nil ? .primary : .secondary)
                    Spacer()
                    if capturedShortcut != nil {
                        Button(L("translation.shortcutSave"), action: saveShortcut)
                    }
                    Button {
                        capturedShortcut = nil
                        errorMessage = nil
                        isRecording.toggle()
                    } label: {
                        Image(systemName: isRecording ? "xmark" : "record.circle")
                    }
                    if shortcutService.binding != nil && !isRecording {
                        Button(role: .destructive, action: shortcutService.clearBinding) {
                            Image(systemName: "trash")
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .overlay {
            GlobalShortcutCaptureView(isRecording: isRecording) { shortcut in
                isRecording = false
                guard let shortcut else { return }
                capturedShortcut = shortcut
                errorMessage = nil
            }
            .frame(width: 1, height: 1)
        }
        .onAppear {
            endpoint = TranslationSettingsValue.placeholderValue(
                endpoint,
                placeholder: TranslationSettingsKey.defaultEndpoint
            )
            if !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let normalizedEndpoint = try? TranslationEndpoint.chatCompletionsURL(from: endpoint) {
                endpoint = normalizedEndpoint.absoluteString
            }
            model = TranslationSettingsValue.placeholderValue(
                model,
                placeholder: TranslationSettingsKey.defaultModel
            )
            if let normalizedEndpoint = try? TranslationEndpoint.chatCompletionsURL(from: endpoint) {
                model = TranslationModel.canonicalName(model, endpoint: normalizedEndpoint)
            }
            apiKey = TranslationAPIKeyStore.load() ?? ""
        }
    }

    private func saveAPIKey() {
        didSaveAPIKey = TranslationAPIKeyStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        if !didSaveAPIKey { errorMessage = L("translation.error.saveAPIKey") }
    }

    private func saveShortcut() {
        guard let capturedShortcut else { return }
        do {
            try shortcutService.setBinding(capturedShortcut)
            self.capturedShortcut = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
