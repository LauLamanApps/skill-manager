import Foundation

enum SemverBump: String {
    case patch, minor, major

    /// Applies the bump with semver reset rules; a missing version counts as 1.0.0.
    func apply(to version: String?) -> String {
        let parts = (version ?? "1.0.0").split(separator: ".").map { Int($0) ?? 0 }
        var major = parts.count > 0 ? parts[0] : 1
        var minor = parts.count > 1 ? parts[1] : 0
        var patch = parts.count > 2 ? parts[2] : 0
        switch self {
        case .patch: patch += 1
        case .minor: minor += 1; patch = 0
        case .major: major += 1; minor = 0; patch = 0
        }
        return "\(major).\(minor).\(patch)"
    }
}

struct ChangeSuggestion {
    var bump: SemverBump
    var summary: String
}

enum VersionAdvisor {
    /// Asks the agent CLI (headless, cheapest model) to classify a skill edit
    /// and summarize it in one line. Any failure — no CLI, bad exit, unparseable
    /// answer — falls back to a patch bump with an empty summary.
    static func suggest(
        fileName: String, old: String, new: String,
        agent: any AgentRunner = AgentRunners.active
    ) async -> ChangeSuggestion {
        let prompt = """
        Compare the old and new version of the file `\(fileName)` belonging to a \
        Claude Code skill. Reply with exactly two lines and nothing else:
        bump: patch|minor|major
        summary: <one sentence, imperative mood, describing what changed>

        bump is patch for typo/wording/formatting fixes (meaning unchanged), \
        minor when new instructions or sections were added (existing ones intact), \
        major when existing instructions were rewritten, changed, or removed.

        OLD:
        \(old)

        NEW:
        \(new)
        """
        let fallback = ChangeSuggestion(bump: .patch, summary: "")
        guard let result = try? await Shell.runInLoginShell(
            agent.oneShotCommand(), stdin: prompt
        ), result.succeeded else { return fallback }

        var suggestion = fallback
        for line in result.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("bump:") {
                let word = trimmed.dropFirst("bump:".count)
                    .trimmingCharacters(in: .whitespaces).lowercased()
                if let bump = SemverBump(rawValue: word) { suggestion.bump = bump }
            } else if trimmed.lowercased().hasPrefix("summary:") {
                suggestion.summary = String(trimmed.dropFirst("summary:".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return suggestion
    }
}
