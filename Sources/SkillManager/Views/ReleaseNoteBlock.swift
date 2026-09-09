import SwiftUI

/// A block of release-note Markdown, classified for display.
///
/// Release notes — whether from a GitHub release body or the bundled
/// `RELEASENOTES.md` — are close to flat: headings, list items, paragraphs and
/// the occasional blockquote. A block-level parse reads better than dumping the
/// raw Markdown into one `Text`, which loses headings/bullets and collapses
/// block spacing.
enum ReleaseNoteBlock {
    case heading(level: Int, text: AttributedString)
    case bullet(text: AttributedString)
    case paragraph(text: AttributedString)
    case quote(text: AttributedString)

    static func parse(_ body: String) -> [ReleaseNoteBlock] {
        var blocks: [ReleaseNoteBlock] = []
        // Markdown hard-wraps: a line that isn't itself a block marker
        // continues the block above it, so lines are accumulated and only
        // flushed on a blank line or the start of the next block.
        var pending: (kind: PendingKind, text: String)?

        func flush() {
            guard let pending, !pending.text.isEmpty else { return }
            let text = inline(pending.text)
            switch pending.kind {
            case .bullet: blocks.append(.bullet(text: text))
            case .paragraph: blocks.append(.paragraph(text: text))
            case .quote: blocks.append(.quote(text: text))
            }
        }

        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flush()
                pending = nil
                continue
            }
            if let level = headingLevel(of: line) {
                flush()
                pending = nil
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: inline(text)))
                continue
            }
            if let text = bulletText(of: line) {
                flush()
                pending = (.bullet, text)
                continue
            }
            if let text = quoteText(of: line) {
                // Every line of a wrapped blockquote carries its own `>`, so a
                // quote continues the quote above it instead of starting one.
                if let current = pending, current.kind == .quote {
                    pending = (.quote, current.text + " " + text)
                } else {
                    flush()
                    pending = (.quote, text)
                }
                continue
            }
            if var current = pending {
                current.text += " " + line
                pending = current
            } else {
                pending = (.paragraph, line)
            }
        }
        flush()
        return blocks
    }

    private enum PendingKind { case bullet, paragraph, quote }

    /// Number of leading `#` characters, if this line is an ATX heading (`# `…`###### `).
    private static func headingLevel(of line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard !hashes.isEmpty, hashes.count <= 6, line.count > hashes.count,
              line[line.index(line.startIndex, offsetBy: hashes.count)] == " " else {
            return nil
        }
        return hashes.count
    }

    /// Strips a leading `-`/`*`/`+` or `1.` list marker, if present.
    private static func bulletText(of line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        if let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            return String(line[range.upperBound...])
        }
        return nil
    }

    /// Strips a leading `>` blockquote marker, if present.
    private static func quoteText(of line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// Renders inline Markdown (bold, links, code) within a block; falls back to
    /// the raw text if it doesn't parse as Markdown.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Renders parsed release-note blocks: shared by the update sheet and the
/// bundled notes in Settings so both read identically.
struct ReleaseNoteBlocksView: View {
    let blocks: [ReleaseNoteBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(for block: ReleaseNoteBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, level <= 2 ? 6 : 4)
        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                Text(text)
            }
        case .paragraph(let text):
            Text(text)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(.quaternary).frame(width: 3)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}
