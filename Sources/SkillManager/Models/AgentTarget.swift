import Foundation

/// An AI agent that can receive installed skills.
///
/// The kinds are built in, but every path is editable: only Claude Code's
/// location is known to be correct. The rest ship as starting points and stay
/// disabled until the user confirms them, so a wrong guess can never silently
/// copy skills into a folder no agent reads.
struct AgentTarget: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case claudeCode
        case codex
        case cursor

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .cursor: "Cursor"
            }
        }

        var icon: String {
            switch self {
            case .claudeCode: "sparkles"
            case .codex: "chevron.left.forwardslash.chevron.right"
            case .cursor: "cursorarrow.rays"
            }
        }

        /// Home-relative default install location.
        var defaultRelativePath: String {
            switch self {
            case .claudeCode: ".claude/skills"
            case .codex: ".codex/skills"
            case .cursor: ".cursor/skills"
            }
        }

        /// Whether `defaultRelativePath` is a verified location rather than a
        /// starting guess. Drives both the default enabled state and the
        /// "check this path" hint in Settings.
        var hasVerifiedPath: Bool { self == .claudeCode }
    }

    let kind: Kind
    var isEnabled: Bool
    var path: String

    var id: Kind { kind }

    var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func makeDefault(_ kind: Kind) -> AgentTarget {
        AgentTarget(
            kind: kind,
            isEnabled: kind.hasVerifiedPath,
            path: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(kind.defaultRelativePath).path
        )
    }

    static var defaults: [AgentTarget] { Kind.allCases.map(makeDefault) }
}
