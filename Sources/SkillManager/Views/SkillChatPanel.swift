import SwiftUI

/// Trailing slide-in panel of the skill window: instruct the configured AI
/// CLI (headless) to manipulate this skill's files.
///
/// The conversation is handed in rather than owned here — this view is torn
/// down whenever the panel slides shut, and a runner living in it would take
/// the transcript, the resumable session and the pending diff down with it.
struct SkillChatPanel: View {
    @EnvironmentObject var store: SkillStore
    @ObservedObject var runner: ClaudeRunner

    let skill: Skill
    /// The editor above has unsaved edits — the agent works on disk, so a run
    /// would silently fight them.
    let isDirty: Bool
    /// Called whenever the files under the editor may have changed: after a
    /// finished edit run, and after a revert.
    let onFilesChanged: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Same header treatment as the info panel's Info/Files tabs, so the
            // two panels read as a pair.
            Picker("", selection: $runner.askOnly) {
                Text("Edit").tag(false)
                Text("Ask").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(runner.isRunning)
            .help("Ask runs read-only — the AI can't change any file.")
            .padding(10)
            Divider()
            conversation
        }
        .onChange(of: runner.finishedSuccessfully) { _, success in
            if success == true, !runner.lastRunWasReadOnly { onFilesChanged() }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The transcript takes the panel's free height; everything below it
            // is composer, pinned to the bottom.
            if runner.isRunning || runner.hasTranscript {
                ChatTranscriptView(turns: runner.turns, isRunning: runner.isRunning)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            } else {
                emptyState
            }
            if !runner.changes.isEmpty {
                DiffReviewView(
                    changes: runner.changes,
                    onKeep: { runner.acceptChanges() },
                    onRevertAll: { Task { await runner.revertAll(); onFilesChanged() } },
                    onRevert: { change in
                        Task { await runner.revert(change); onFilesChanged() }
                    }
                )
                .frame(maxHeight: 220)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            if let error = runner.revertError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            TextField(
                runner.askOnly
                    ? "Ask the AI about this skill…"
                    : "Ask the AI to change this skill's files…",
                text: $runner.draft,
                axis: .vertical
            )
            .lineLimit(1...5)
            .textFieldStyle(.roundedBorder)
            .onSubmit(run)
            .disabled(runner.isRunning)

            HStack(spacing: 8) {
                // Shares the composer's button row: the row had nothing on its
                // leading side, and the credit belongs beside the control that
                // hands work to the agent it names.
                AgentCreditLine(agent: runner.agent)
                    .layoutPriority(-1)

                Spacer(minLength: 8)

                if !runner.isRunning, runner.hasTranscript {
                    Button {
                        runner.reset()
                    } label: {
                        Image(systemName: "plus.bubble")
                    }
                    .help("Forget this conversation and start a fresh session")
                }

                if runner.isRunning {
                    Button {
                        runner.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop the running call")
                }

                Button {
                    run()
                } label: {
                    if runner.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(!canRun)
                .help("Run the AI on this skill's directory")
            }
            if isDirty {
                Text("Save your changes first — the AI edits the files on disk.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !runner.agent.supportsResume, runner.hasTranscript {
                Text("This AI can't resume a session — each message starts a fresh run.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    /// Holds the panel open before the first message, so the composer sits at
    /// the bottom instead of floating in the middle of an empty panel.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Edit with AI", systemImage: "sparkles")
                .font(.callout.weight(.medium))
            Text("Describe a change and the AI edits this skill's files. Switch to Ask to have it read them without writing anything.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(6)
    }

    private var canRun: Bool {
        !runner.isRunning && !isDirty
            && !runner.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func run() {
        guard canRun else { return }
        let instruction = runner.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        runner.draft = ""
        runner.run(
            instruction: instruction,
            cwd: skill.path,
            context: "Edit the existing skill \"\(skill.name)\". You are already "
                + "inside its directory — its SKILL.md is at ./SKILL.md.",
            ignoring: store.ignoreMatcher(for: skill),
            readOnly: runner.askOnly,
            model: store.agentCLI.modelArgument
        )
    }
}
