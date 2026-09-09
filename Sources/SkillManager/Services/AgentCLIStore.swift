import Foundation

/// On-disk home of the agent choice, next to `agent-targets.json`.
///
/// ```
/// Application Support/SkillManager/
///   agent-cli.json     which CLI drives the app, its path and its model
/// ```
enum AgentCLIStore {
    static var fileURL: URL {
        CatalogStore.supportDir.appendingPathComponent("agent-cli.json")
    }

    /// The stored choice, or Claude Code when the file is missing or
    /// unreadable — the same rule `AgentTargetStore` follows: a bad file costs
    /// a preference, it must never leave the app unable to run anything.
    static func load() -> AgentCLI {
        guard
            let data = try? Data(contentsOf: fileURL),
            var stored = try? JSONDecoder().decode(AgentCLI.self, from: data)
        else { return migratedDefault() }
        // An empty path and no path mean the same thing; normalizing here keeps
        // `launchPath` the only place that has to know it.
        if stored.binaryPath?.isEmpty == true { stored.binaryPath = nil }
        return stored
    }

    static func save(_ cli: AgentCLI) throws {
        try FileManager.default.createDirectory(
            at: CatalogStore.supportDir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cli).write(to: fileURL, options: .atomic)
    }

    /// Before this file existed, the model was a `UserDefaults` value written by
    /// the Settings pane. Carry it over so the setting survives the move.
    private static func migratedDefault() -> AgentCLI {
        var cli = AgentCLI.claudeCode
        cli.model = UserDefaults.standard.string(forKey: "claudeModel") ?? ""
        return cli
    }
}
