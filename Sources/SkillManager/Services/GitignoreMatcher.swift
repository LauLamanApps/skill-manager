import Foundation

/// Simplified .gitignore matcher: the catalog's .gitignore doubles as the
/// guard for what the UI shows and what skill copies carry along.
///
/// Supported per line: comments (#), directory patterns (`build/`), glob
/// patterns on a single name (`*.pyc`), and path patterns containing `/`
/// (`docs/*.tmp`). `!` negation is not supported and such lines are skipped.
/// Simplification: a directory pattern also matches a plain file of that name.
struct GitignoreMatcher {
    /// Matched via fnmatch against every path component.
    private let componentPatterns: [String]
    /// Matched via fnmatch against the whole relative path.
    private let pathPatterns: [String]

    static let defaultPatterns = [
        "__pycache__/", "*.pyc", "node_modules/", ".venv/", "venv/", ".DS_Store",
    ]

    static var defaultFileContents: String {
        "# Managed by Skill Manager — also hides matching files in its UI.\n"
            + defaultPatterns.joined(separator: "\n") + "\n"
    }

    init(lines: [String]) {
        var components: [String] = []
        var paths: [String] = []
        for line in lines {
            var pattern = line.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty, !pattern.hasPrefix("#"), !pattern.hasPrefix("!") else {
                continue
            }
            if pattern.hasSuffix("/") { pattern = String(pattern.dropLast()) }
            if pattern.hasPrefix("/") { pattern = String(pattern.dropFirst()) }
            if pattern.contains("/") {
                paths.append(pattern)
            } else {
                components.append(pattern)
            }
        }
        componentPatterns = components
        pathPatterns = paths
    }

    /// Defaults plus whatever the catalog's .gitignore adds.
    static func forCatalog(gitignore: URL) -> GitignoreMatcher {
        var lines = defaultPatterns
        if let content = try? String(contentsOf: gitignore, encoding: .utf8) {
            lines += content.components(separatedBy: "\n")
        }
        return GitignoreMatcher(lines: lines)
    }

    func isIgnored(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        for pattern in componentPatterns {
            for component in components where fnmatch(pattern, component, 0) == 0 {
                return true
            }
        }
        for pattern in pathPatterns where fnmatch(pattern, relativePath, 0) == 0 {
            return true
        }
        return false
    }
}
