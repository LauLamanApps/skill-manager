import Foundation

/// Runs a catalog skill in a throwaway agent session without installing it.
///
/// Every trial is a scratch workspace plus a symlink to the real skill
/// directory — the symlink keeps the trial in sync with edits made in the app,
/// and nothing is ever copied into an installed skills folder. *Where* that
/// symlink goes is the agent's business: Claude Code wants a plugin directory
/// to pass on the command line, Codex wants the skill inside the working
/// directory it will scan. `TrialLayout` names the two shapes; an agent that
/// has neither reports no layout at all and a trial refuses to start.
enum SkillTrial {
    enum Failure: LocalizedError {
        /// The configured agent has no way to load a skill without installing it.
        case unsupported(agent: String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let agent):
                "\(agent) cannot load a skill for a single session, so it can't run a trial."
            }
        }
    }

    /// Trials live in the app's temp directory — throwaway by construction, and
    /// swept by macOS even if the app never gets to prune them.
    static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillManagerTrials", isDirectory: true)
    }

    /// Builds the throwaway plugin and opens a Terminal window running the
    /// agent with it.
    @discardableResult
    static func start(
        _ skill: Skill, model: String? = nil, agent: any AgentRunner = AgentRunners.active
    ) async throws -> URL {
        let dir = try prepare(skill, model: model, agent: agent)
        try await Shell.runChecked(
            "/usr/bin/open", ["-a", "Terminal", dir.appendingPathComponent(scriptName).path]
        )
        return dir
    }

    private static let scriptName = "try-skill.command"

    /// Lays out `<trial>/{workspace/, try-skill.command}` plus whichever skill
    /// layout the agent needs, and returns the trial directory.
    static func prepare(
        _ skill: Skill, model: String? = nil, agent: any AgentRunner = AgentRunners.active
    ) throws -> URL {
        guard let layout = agent.trialLayout else {
            throw Failure.unsupported(agent: agent.displayName)
        }
        let fm = FileManager.default
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = dir.appendingPathComponent("workspace", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)

        let trial = PreparedTrial(root: dir, workspace: workspace, skillName: skill.name)
        switch layout {
        case .plugin: try buildPlugin(for: skill, in: trial)
        case .workspaceSkills: try buildWorkspaceSkills(for: skill, in: trial)
        }

        let script = dir.appendingPathComponent(scriptName)
        try launchScript(skill: skill, trial: trial, layout: layout, model: model, agent: agent)
            .write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        return dir
    }

    /// A one-skill plugin at the trial root: `.claude-plugin/plugin.json` plus
    /// `skills/<skill>`, for a CLI that takes a plugin directory as an argument.
    private static func buildPlugin(for skill: Skill, in trial: PreparedTrial) throws {
        let fm = FileManager.default
        let skillsDir = trial.root.appendingPathComponent("skills", isDirectory: true)
        try fm.createDirectory(
            at: trial.root.appendingPathComponent(".claude-plugin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        let manifest = """
            {
              "name": "\(TrialLayout.pluginName)",
              "description": "Ad hoc skill trial started from Skill Manager.",
              "version": "0.0.0"
            }
            """
        try manifest.write(
            to: trial.root.appendingPathComponent(".claude-plugin/plugin.json"),
            atomically: true, encoding: .utf8
        )
        try link(skill, into: skillsDir)
    }

    /// The skill inside the workspace itself, at `.agents/skills/<skill>`, for
    /// a CLI that discovers skills by scanning upward from its working
    /// directory. Nothing is passed on the command line — starting the session
    /// in the workspace is the whole mechanism.
    private static func buildWorkspaceSkills(for skill: Skill, in trial: PreparedTrial) throws {
        let skillsDir = trial.workspace
            .appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try link(skill, into: skillsDir)
    }

    /// Links rather than copies, so edits made in the app while the trial is
    /// open reach the session.
    private static func link(_ skill: Skill, into skillsDir: URL) throws {
        try FileManager.default.createSymbolicLink(
            at: skillsDir.appendingPathComponent(skill.path.lastPathComponent),
            withDestinationURL: skill.path.standardizedFileURL
        )
    }

    /// A `.command` file so `open -a Terminal` runs it in a fresh window. The
    /// login shell is what makes the agent binary findable, same as `Shell`'s
    /// helpers.
    private static func launchScript(
        skill: Skill, trial: PreparedTrial, layout: TrialLayout, model: String?,
        agent: any AgentRunner
    ) throws -> String {
        guard let command = agent.trialCommand(trial, model: model) else {
            throw Failure.unsupported(agent: agent.displayName)
        }
        return """
            #!/bin/zsh -l
            cd \(quoted(trial.workspace.path)) || exit 1
            clear
            cat <<'BANNER'
            Trying “\(skill.name)” — loaded for this session only, not installed.

              Invoke it with:  \(layout.invocation(for: skill.name))
              Scratch folder:  \(trial.workspace.path)

            Nothing was installed. Close this window when done.
            BANNER
            echo
            exec \(command)

            """
    }

    /// Every path here can contain spaces (Application Support) — quote them all.
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Drops trial directories from earlier runs. Age-based rather than
    /// wholesale: a Terminal window from a previous app session may still have
    /// its trial open, and pulling the plugin out from under it would break it.
    static func pruneStale(olderThan age: TimeInterval = 24 * 60 * 60) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if let created, created > cutoff { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
