import Foundation

/// One `## <version>` section of the release notes.
struct ReleaseNoteSection: Identifiable {
    /// Heading text as written, e.g. `0.2.0 — 2026-09-08`.
    let title: String
    /// Markdown under the heading, up to the next `## ` heading.
    let body: String

    var id: String { title }

    /// The version alone, without the ` — <date>` suffix.
    var version: String {
        title.components(separatedBy: " — ").first?
            .trimmingCharacters(in: .whitespaces) ?? title
    }
}

/// Reads `RELEASENOTES.md` out of the app bundle. `scripts/build-app.sh` copies
/// it in at build time with the "Unreleased" heading already stamped with the
/// version being built, so what the app shows matches what it is.
enum ReleaseNotes {
    /// Sections newest-first, matching the file's own order. Empty when the app
    /// runs unbundled (`swift run`), where there is no resource to read.
    static let bundled: [ReleaseNoteSection] = {
        guard let url = Bundle.main.url(forResource: "RELEASENOTES", withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return parse(markdown)
    }()

    /// Splits the notes on `## ` headings. Anything before the first one — the
    /// `# Release Notes` title — is dropped.
    static func parse(_ markdown: String) -> [ReleaseNoteSection] {
        var sections: [ReleaseNoteSection] = []
        var title: String?
        var body: [String] = []

        func flush() {
            guard let title else { return }
            sections.append(
                ReleaseNoteSection(
                    title: title,
                    body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                flush()
                title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                body = []
            } else if title != nil {
                body.append(line)
            }
        }
        flush()
        return sections
    }
}
