import Foundation

/// Runs a catalog skill in a throwaway Claude Code session without installing it.
///
/// The CLI has no "load just this skill" flag, but `--plugin-dir` loads a whole
/// plugin directory for one session only. So a trial is a minimal plugin built
/// on the fly: a `plugin.json` plus a symlink to the real skill directory. The
/// symlink keeps the trial in sync with edits made in the app, and nothing is
/// ever copied into `~/.claude/skills`.
enum SkillTrial {
    /// Plugin name the trial skill is namespaced under, so it reads as
    /// `/trial:<skill-name>` in the session and can't be confused with an
    /// installed copy of the same skill.
    static let pluginName = "trial"

    /// Trials live in the app's temp directory — throwaway by construction, and
    /// swept by macOS even if the app never gets to prune them.
    static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillManagerTrials", isDirectory: true)
    }

    /// Builds the throwaway plugin and opens a Terminal window running Claude
    /// Code with it.
    @discardableResult
    static func start(_ skill: Skill, model: String? = nil) async throws -> URL {
        let dir = try prepare(skill, model: model)
        try await Shell.runChecked(
            "/usr/bin/open", ["-a", "Terminal", dir.appendingPathComponent(scriptName).path]
        )
        return dir
    }

    private static let scriptName = "try-skill.command"

    /// Lays out `<trial>/{.claude-plugin/plugin.json, skills/<skill> -> …,
    /// workspace/, try-skill.command}` and returns the trial directory.
    static func prepare(_ skill: Skill, model: String? = nil) throws -> URL {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = dir.appendingPathComponent("skills", isDirectory: true)
        let workspace = dir.appendingPathComponent("workspace", isDirectory: true)

        try fm.createDirectory(
            at: dir.appendingPathComponent(".claude-plugin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)

        let manifest = """
            {
              "name": "\(pluginName)",
              "description": "Ad hoc skill trial started from Skill Manager.",
              "version": "0.0.0"
            }
            """
        try manifest.write(
            to: dir.appendingPathComponent(".claude-plugin/plugin.json"),
            atomically: true, encoding: .utf8
        )

        try fm.createSymbolicLink(
            at: skillsDir.appendingPathComponent(skill.path.lastPathComponent),
            withDestinationURL: skill.path.standardizedFileURL
        )

        let script = dir.appendingPathComponent(scriptName)
        try launchScript(skill: skill, trialDir: dir, workspace: workspace, model: model)
            .write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        return dir
    }

    /// A `.command` file so `open -a Terminal` runs it in a fresh window. The
    /// login shell is what makes `claude` findable, same as `Shell`'s helpers.
    private static func launchScript(
        skill: Skill, trialDir: URL, workspace: URL, model: String?
    ) -> String {
        var command = "claude --plugin-dir \(quoted(trialDir.path))"
        if let model, !model.isEmpty {
            command += " --model \(quoted(model))"
        }
        return """
            #!/bin/zsh -l
            cd \(quoted(workspace.path)) || exit 1
            clear
            cat <<'BANNER'
            Trying “\(skill.name)” — loaded for this session only, not installed.

              Invoke it with:  /\(pluginName):\(skill.name)
              Scratch folder:  \(workspace.path)

            Nothing was written to ~/.claude/skills. Close this window when done.
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
