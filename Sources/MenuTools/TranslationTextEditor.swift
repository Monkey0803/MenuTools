import AppKit
import SwiftUI

struct TranslationTextEditorConfiguration: Equatable {
    let isEditable: Bool
    let isSelectable: Bool
    let showsVerticalScroller: Bool

    init(isEditable: Bool) {
        self.isEditable = isEditable
        isSelectable = true
        showsVerticalScroller = true
    }
}

struct TranslationTextEditor: NSViewRepresentable {
    @Binding var text: String
    let configuration: TranslationTextEditorConfiguration

    init(text: Binding<String>, isEditable: Bool) {
        _text = text
        configuration = TranslationTextEditorConfiguration(isEditable: isEditable)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, configuration: configuration)
    }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(
            text: text,
            configuration: configuration,
            delegate: context.coordinator
        )
    }

    static func makeScrollView(
        text: String,
        configuration: TranslationTextEditorConfiguration,
        delegate: (any NSTextViewDelegate)?
    ) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = configuration.showsVerticalScroller
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false

        let textView = NSTextView()
        textView.delegate = delegate
        textView.string = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.drawsBackground = false
        textView.isEditable = configuration.isEditable
        textView.isSelectable = configuration.isSelectable
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.text = $text
        textView.isEditable = configuration.isEditable
        textView.isSelectable = configuration.isSelectable
        scrollView.hasVerticalScroller = configuration.showsVerticalScroller

        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let configuration: TranslationTextEditorConfiguration

        init(text: Binding<String>, configuration: TranslationTextEditorConfiguration) {
            self.text = text
            self.configuration = configuration
        }

        func textDidChange(_ notification: Notification) {
            guard configuration.isEditable,
                  let textView = notification.object as? NSTextView else {
                return
            }

            text.wrappedValue = textView.string
        }
    }
}
