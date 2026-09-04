import SwiftUI

struct TranslationWindowView: View {
    @Bindable var model: TranslationWindowModel

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(L("translation.windowTitle"), systemImage: "character.bubble")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker(L("translation.targetLanguage"), selection: Binding(
                    get: { model.targetLanguage },
                    set: { model.setTargetLanguage($0) }
                )) {
                    ForEach(TranslationLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            translationEditor(
                title: L("translation.source"),
                text: $model.sourceText,
                isEditable: true
            )

            translationEditor(
                title: L("translation.result"),
                text: Binding(get: { model.translatedText }, set: { _ in }),
                isEditable: false
            )

            HStack(spacing: 12) {
                if model.isTranslating {
                    ProgressView().controlSize(.small)
                    Text(L("translation.translating"))
                        .foregroundStyle(.secondary)
                } else if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button(L("translation.copy"), action: model.copyTranslation)
                    .disabled(model.translatedText.isEmpty)
                Button(L("translation.translate"), action: model.translate)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isTranslating)
            }
        }
        .padding(20)
    }

    private func translationEditor(title: String, text: Binding<String>, isEditable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TranslationTextEditor(text: text, isEditable: isEditable)
                .padding(8)
                .background(.quaternary, in: .rect(cornerRadius: 10))
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
