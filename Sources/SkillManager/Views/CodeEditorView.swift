import SwiftUI
import AppKit

/// Editable code view with syntax highlighting (NSTextView-backed).
/// Re-highlights on every edit and when the bound text or language changes
/// from outside (e.g. switching files).
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = SyntaxHighlighter.font
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        scrollView.drawsBackground = false
        context.coordinator.textView = textView
        textView.string = text
        context.coordinator.highlight(language: language)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight(language: language)
        } else if context.coordinator.lastLanguage != language {
            context.coordinator.highlight(language: language)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: NSTextView?
        var lastLanguage: CodeLanguage = .plain

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            highlight(language: parent.language)
        }

        func highlight(language: CodeLanguage) {
            lastLanguage = language
            guard let storage = textView?.textStorage else { return }
            SyntaxHighlighter.highlight(storage, language: language)
        }
    }
}
