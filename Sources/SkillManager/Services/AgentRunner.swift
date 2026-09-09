import Foundation

/// An AI coding CLI the app can drive: how to invoke it, how to read what it
/// streams back, and what it is capable of.
///
/// Everything CLI-specific — flag names, subcommands, wire format, the binary's
/// own name — lives behind this protocol. `ClaudeRunner` (the conversation) and
/// the views above it only ever see `AgentStreamEvent` and the capability flags.
///
/// Implementations are stateless value types: one instance describes the CLI,
/// not a running conversation.
protocol AgentRunner: Sendable {
    /// Name for the UI, e.g. "Claude Code".
    var displayName: String { get }

    /// Binary the CLI ships as, for "not found in PATH"-style messages.
    var binaryName: String { get }

    /// Streaming command for one conversation turn.
    ///
    /// `sessionID` continues an earlier turn (only ever non-nil when
    /// `supportsResume` is true), `readOnly` must refuse every edit, and `model`
    /// is the user's model override, empty or nil meaning the CLI's default.
    func command(resuming sessionID: String?, readOnly: Bool, model: String?) -> String

    /// Non-streaming command for a short classification prompt fed over stdin,
    /// answered on plain stdout. The agent picks its own cheapest model — the
    /// caller has no opinion beyond wanting the answer quickly.
    func oneShotCommand() -> String

    /// How an ad-hoc trial skill has to be laid out on disk for this CLI to
    /// find it, or nil when the CLI cannot load a skill without installing it.
    /// `supportsTrials` is derived from this.
    var trialLayout: TrialLayout? { get }

    /// Interactive command that runs `trial` without installing anything, or
    /// nil when the CLI has no such mechanism. The session's working directory
    /// is `trial.workspace`; a layout the CLI discovers from the cwd needs no
    /// arguments at all beyond the model.
    func trialCommand(_ trial: PreparedTrial, model: String?) -> String?

    /// Decodes one line of streaming output.
    func parse(line: String) -> AgentStreamLine

    /// Version string of the installed binary, or nil when it is not reachable
    /// from a login shell.
    func checkAvailability() async -> String?

    /// Whether a later turn can continue an earlier session. When false, every
    /// turn starts fresh and the conversation carries no context.
    var supportsResume: Bool { get }

    /// Whether the stream reports individual tool calls, so the transcript can
    /// show what the agent is doing rather than just its prose.
    var supportsToolCards: Bool { get }
}

extension AgentRunner {
    /// Whether a skill can be loaded ad hoc for a trial run (Try it). A runner
    /// that describes a layout can trial by construction, so the two can never
    /// disagree.
    var supportsTrials: Bool { trialLayout != nil }

    /// Shell-quotes a path or argument. Every path the app passes can contain
    /// spaces (Application Support), so quoting is not optional.
    func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// How an agent expects an ad-hoc trial skill to be laid out on disk, and how
/// the user then invokes it once the session is up.
///
/// The two CLIs differ at the root here: Claude Code takes a plugin directory
/// on the command line, while Codex has no such flag and instead discovers
/// skills by directory convention, scanning `.agents/skills/` from the working
/// directory upward. `SkillTrial` builds whichever layout the active runner
/// asks for; neither one copies the skill, so edits in the app stay live.
enum TrialLayout {
    /// `<trial>/.claude-plugin/plugin.json` plus `<trial>/skills/<skill>`,
    /// handed to the CLI as a plugin directory.
    case plugin

    /// `<trial>/workspace/.agents/skills/<skill>`, found by the CLI because the
    /// session's working directory is that workspace.
    case workspaceSkills

    /// Plugin name a `.plugin` trial is namespaced under, so it reads as
    /// `/trial:<skill>` in the session and can't be confused with an installed
    /// copy of the same skill.
    static let pluginName = "trial"

    /// What the user types to invoke the trial skill: a namespaced slash
    /// command for a plugin, a `$mention` for a discovered skill.
    func invocation(for skillName: String) -> String {
        switch self {
        case .plugin: "/\(Self.pluginName):\(skillName)"
        case .workspaceSkills: "$\(skillName)"
        }
    }
}

/// A trial laid out on disk, ready for a runner to turn into a command.
struct PreparedTrial {
    /// Throwaway directory holding the whole trial.
    var root: URL

    /// Scratch folder the session runs in, and the only place it should write.
    var workspace: URL

    /// The skill on trial, named as the user invokes it.
    var skillName: String
}

extension AgentCLI {
    /// The runner driving this configuration, or nil when the app has no
    /// adapter for the chosen kind yet.
    ///
    /// A `Kind` exists here before its runner does, so a choice made in a later
    /// release still decodes instead of being thrown away.
    var runner: (any AgentRunner)? {
        switch kind {
        case .claudeCode: ClaudeCodeRunner(launchPath: launchPath)
        case .codex: CodexRunner(launchPath: launchPath)
        }
    }
}

extension AgentCLI.Kind {
    /// Whether the app can actually drive this CLI today. The Settings picker
    /// only offers the kinds that can.
    var hasRunner: Bool {
        AgentCLI(kind: self, binaryPath: nil, model: "").runner != nil
    }
}

/// The runner every entry point resolves through.
///
/// Holds the user's choice in memory so a `command()` deep inside a run never
/// touches the disk. `SkillStore` owns the published copy and pushes each
/// change here after persisting it.
enum AgentRunners {
    private static let box = ConfigurationBox()

    static var configuration: AgentCLI {
        get { box.value }
        set { box.value = newValue }
    }

    /// Falls back to Claude Code when the stored kind has no adapter. Only
    /// reachable through a hand-edited `agent-cli.json` — and running the
    /// reference CLI beats refusing to run anything at all.
    static var active: any AgentRunner {
        configuration.runner ?? ClaudeCodeRunner()
    }
}

/// Lock-guarded: `active` is read from whatever thread a run starts on, while
/// the setter only ever fires from the main actor.
private final class ConfigurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = AgentCLIStore.load()

    var value: AgentCLI {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
