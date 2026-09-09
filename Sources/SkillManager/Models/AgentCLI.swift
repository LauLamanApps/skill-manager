import Foundation

/// The AI CLI that drives the app: which agent runs skills, where its binary
/// lives, and which model it should use.
///
/// Deliberately not `AgentTarget`. That one says where skills are *installed*;
/// this one says what *runs* them. A user may install into Codex while still
/// driving the app with Claude Code, so the two choices never share a model.
struct AgentCLI: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case claudeCode
        case codex

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            }
        }

        /// Binary the CLI ships as, used whenever no explicit path is set.
        var binaryName: String {
            switch self {
            case .claudeCode: "claude"
            case .codex: "codex"
            }
        }

        /// Models offered as a picker. Empty means the app doesn't know the
        /// CLI's model names and the user types one instead — Codex's
        /// model-selection flag is still unverified.
        var modelOptions: [String] {
            switch self {
            case .claudeCode: ["haiku", "sonnet", "opus"]
            case .codex: []
            }
        }
    }

    var kind: Kind
    /// Absolute path to the binary. Nil resolves the CLI from the login shell
    /// PATH, which is right for every normal install; a path is for the ones
    /// installed somewhere a login shell doesn't look.
    var binaryPath: String?
    /// Model override. Empty means the CLI's own default.
    var model: String

    /// How the CLI is invoked: the configured path when there is one, the bare
    /// binary name otherwise.
    var launchPath: String {
        guard let binaryPath, !binaryPath.isEmpty else { return kind.binaryName }
        return binaryPath
    }

    /// The model to hand a run, or nil to let the CLI pick its own.
    var modelArgument: String? { model.isEmpty ? nil : model }

    static let claudeCode = AgentCLI(kind: .claudeCode, binaryPath: nil, model: "")
}
