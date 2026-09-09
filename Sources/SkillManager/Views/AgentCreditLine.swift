import SwiftUI

/// One-line "who is actually running this" credit for the chat surfaces.
///
/// The copy around it stays agent-neutral — it says "the AI", because the CLI
/// behind it is a setting and naming Claude Code in every sentence is wrong the
/// moment someone points the app at Codex. The concrete name and model belong
/// somewhere, though, so they live here: once per surface, quietly.
struct AgentCreditLine: View {
    @EnvironmentObject var store: SkillStore
    let agent: any AgentRunner

    var body: some View {
        Text("\(agent.displayName) · \(modelLabel)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help("Change the agent and model in Settings › Agent")
    }

    /// An empty model means "whatever the CLI defaults to" — say that rather
    /// than showing a blank half of the line.
    private var modelLabel: String {
        let model = store.agentCLI.model
        return model.isEmpty ? "default model" : model
    }
}
