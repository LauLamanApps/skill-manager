import Foundation

/// One thing wrong with a skill's SKILL.md. Advisory only — nothing in the app
/// refuses to install, sync or edit a skill because of these.
enum SkillIssue: Hashable {
    case missingDescription
    case missingVersion
    case noTags
    case longBody(lines: Int)

    /// Short form for a tooltip line.
    var label: String {
        switch self {
        case .missingDescription: return "No description"
        case .missingVersion: return "No version"
        case .noTags: return "No tags"
        case .longBody(let lines): return "SKILL.md is \(lines) lines long"
        }
    }

    /// Why it matters, for the inspector.
    var detail: String {
        switch self {
        case .missingDescription:
            return "Claude reads the description to decide when to load the skill."
        case .missingVersion:
            return "Without a version, updates against the catalog can't be tracked."
        case .noTags:
            return "Tags drive the filter bar; an untagged skill only turns up via search."
        case .longBody:
            return "Move reference material into separate files and link them from SKILL.md."
        }
    }
}

enum SkillHealth {
    /// Past this, SKILL.md stops being "focused and actionable" — the same rule
    /// the AI authoring prompt hands to Claude (`ClaudeRunner.skillAuthoringPrompt`).
    static let bodyLineLimit = 500

    /// Checks the raw SKILL.md contents. Order is stable, so the UI can show the
    /// first issue as a summary without it jumping around between refreshes.
    static func check(content: String) -> [SkillIssue] {
        let meta = Frontmatter.parse(content)
        let body = Frontmatter.split(content).body

        var issues: [SkillIssue] = []
        if (meta.description ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.missingDescription)
        }
        if (meta.version ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.missingVersion)
        }
        if meta.tags.isEmpty {
            issues.append(.noTags)
        }
        let lines = lineCount(of: body)
        if lines > bodyLineLimit {
            issues.append(.longBody(lines: lines))
        }
        return issues
    }

    /// Lines of actual content — trailing blank lines don't count against the limit.
    private static func lineCount(of body: String) -> Int {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.components(separatedBy: "\n").count
    }
}
