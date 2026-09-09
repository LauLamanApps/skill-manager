import Foundation

/// On-disk home of the agent target list, next to `catalogs.json`.
///
/// ```
/// Application Support/SkillManager/
///   agent-targets.json     enabled state and install path per agent
/// ```
enum AgentTargetStore {
    static var fileURL: URL {
        CatalogStore.supportDir.appendingPathComponent("agent-targets.json")
    }

    /// Stored settings, reconciled against the built-in kinds: a kind added in a
    /// later release appears with its defaults instead of vanishing, and a kind
    /// dropped from the app stops being read. Unreadable JSON falls back to the
    /// defaults rather than throwing — losing a toggle is recoverable, and the
    /// app must still be able to install to Claude Code.
    static func load() -> [AgentTarget] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode([AgentTarget].self, from: data)
        else { return AgentTarget.defaults }

        return AgentTarget.Kind.allCases.map { kind in
            stored.first { $0.kind == kind } ?? .makeDefault(kind)
        }
    }

    static func save(_ targets: [AgentTarget]) throws {
        try FileManager.default.createDirectory(
            at: CatalogStore.supportDir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(targets).write(to: fileURL, options: .atomic)
    }
}
