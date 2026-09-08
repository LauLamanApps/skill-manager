import SwiftUI

/// Bottom panel of the skill detail: instruct Claude Code (headless) to
/// manipulate this skill's files.
///
/// The conversation is handed in rather than owned here — the detail column is
/// rebuilt from scratch on every skill switch, and a runner living in this view
/// would take the transcript, the resumable session and the pending diff down
/// with it.
struct SkillChatPanel: View {
    @EnvironmentObject var store: SkillStore
    @ObservedObject var runner: ClaudeRunner
    @AppStorage("claudeModel") private var claudeModel: String = ""

    let skill: Skill
    /// The editor above has unsaved edits — Claude works on disk, so a run
    /// would silently fight them.
    let isDirty: Bool
    /// Called whenever the files under the editor may have changed: after a
    /// finished edit run, and after a revert.
    let onFilesChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if runner.isRunning || runner.hasTranscript {
                ChatTranscriptView(turns: runner.turns, isRunning: runner.isRunning)
                    .frame(height: 110)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
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
            HStack(alignment: .bottom, spacing: 8) {
                Picker("", selection: $runner.askOnly) {
                    Text("Edit").tag(false)
                    Text("Ask").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .disabled(runner.isRunning)
                .help("Ask runs read-only — Claude Code can't change any file.")

                TextField(
                    runner.askOnly
                        ? "Ask Claude about this skill…"
                        : "Ask Claude to change this skill's files…",
                    text: $runner.draft,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit(run)
                .disabled(runner.isRunning)

                if !runner.isRunning, runner.hasTranscript {
                    Button {
                        runner.reset()
                    } label: {
                        Image(systemName: "plus.bubble")
                    }
                    .help("Forget this conversation and start a fresh Claude Code session")
                }

                if runner.isRunning {
                    Button {
                        runner.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop the running Claude Code call")
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
                .help("Run Claude Code on this skill's directory")
            }
            if isDirty {
                Text("Save your changes first — Claude edits the files on disk.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .onChange(of: runner.finishedSuccessfully) { _, success in
            if success == true, !runner.lastRunWasReadOnly { onFilesChanged() }
        }
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
            ignoring: store.ignoreMatcher,
            readOnly: runner.askOnly,
            model: claudeModel.isEmpty ? nil : claudeModel
        )
    }
}
