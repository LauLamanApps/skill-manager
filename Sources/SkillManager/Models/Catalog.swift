import Foundation

/// One skill catalog: a git repository cloned into `catalogs/<slug>/`.
///
/// `slug` is the folder name on disk. It is derived from the repo name once, at
/// creation time, and then kept as-is — renaming the catalog changes `name`, not
/// the directory, so an existing clone is never orphaned.
struct Catalog: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var repoURL: String
    var slug: String

    init(id: UUID = UUID(), name: String, repoURL: String, slug: String) {
        self.id = id
        self.name = name
        self.repoURL = repoURL
        self.slug = slug
    }

    /// Builds a catalog from a repo URL alone: the repo name becomes the display
    /// name, its slug the folder — uniquified against `taken`.
    static func fromRepoURL(_ repoURL: String, taken: Set<String> = []) -> Catalog {
        let repo = repoName(from: repoURL)
        return Catalog(
            name: repo.isEmpty ? "Catalog" : repo,
            repoURL: repoURL.trimmingCharacters(in: .whitespacesAndNewlines),
            slug: uniqueSlug(base: slugify(repo), taken: taken)
        )
    }

    /// The bare repository name: `git@github.com:you/skills-catalog.git` and
    /// `https://github.com/you/skills-catalog/` both yield `skills-catalog`.
    static func repoName(from repoURL: String) -> String {
        var s = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix(".git") { s.removeLast(4) }
        if let cut = s.lastIndex(where: { $0 == "/" || $0 == ":" }) {
            s = String(s[s.index(after: cut)...])
        }
        return s
    }

    /// Lowercased ASCII alphanumerics with single dashes between them — safe as a
    /// directory name on every filesystem the app touches.
    static func slugify(_ raw: String) -> String {
        var out = ""
        for ch in raw.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "catalog" : out
    }

    /// `base`, or `base-2`, `base-3`, … when the folder name is already in use.
    static func uniqueSlug(base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
