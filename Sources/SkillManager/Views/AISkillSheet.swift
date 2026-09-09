import SwiftUI

enum AISkillMode {
    case create
    case edit(Skill)

    var title: String {
        switch self {
        case .create: return "New Skill with AI"
        case .edit(let skill): return "Edit “\(skill.name)” with AI"
        }
    }
}

/// Sheet that drives the configured AI CLI headless to create or edit a skill
/// in the catalog.
///
/// The conversation lives in `ChatSessionStore`, not in this view: closing the
/// sheet — or navigating to another skill, which closes it — must not throw the
/// transcript and the pending diff away.
struct AISkillSheet: View {
    @EnvironmentObject var store: SkillStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var runner: ClaudeRunner

    let mode: AISkillMode

    @State private var skillName = ""
    @State private var folder = ""
    @State private var catalogID: UUID?

    /// The catalog the session writes into. The create case picks it from the
    /// dropdown below; the edit case inherits it from the skill being edited so
    /// The agent always runs against the repo the file actually lives in.
    private var targetCatalog: Catalog? {
        switch mode {
        case .create: return store.catalog(withID: catalogID) ?? store.primaryCatalog
        case .edit(let skill): return store.catalog(withID: skill.catalogID) ?? store.primaryCatalog
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(mode.title).font(.title3.bold())
                Spacer()
                Picker("", selection: $runner.askOnly) {
                    Text("Edit").tag(false)
                    Text("Ask").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .disabled(runner.isRunning)
                .help("Ask runs read-only — the AI can't change any file.")
            }

            if case .create = mode {
                TextField(
                    "Skill name (optional — leave empty to let AI pick one)",
                    text: $skillName
                )
                .textFieldStyle(.roundedBorder)
                if store.catalogs.count > 1 {
                    Picker("Catalog:", selection: $catalogID) {
                        ForEach(store.catalogs) { catalog in
                            Text(catalog.name).tag(catalog.id as UUID?)
                        }
                    }
                    .disabled(runner.isRunning || runner.hasTranscript)
                }
                TextField("Catalog folder (optional, e.g. frontend or lang/php)", text: $folder)
                    .textFieldStyle(.roundedBorder)
            }

            Text(instructionLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $runner.draft)
                .font(.body)
                .frame(minHeight: 90, maxHeight: 140)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            if runner.isRunning || runner.hasTranscript {
                GroupBox {
                    ChatTranscriptView(turns: runner.turns, isRunning: runner.isRunning)
                        .frame(minHeight: 120, maxHeight: 220)
                }
            }

            if !runner.changes.isEmpty {
                GroupBox {
                    DiffReviewView(
                        changes: runner.changes,
                        onKeep: { runner.acceptChanges() },
                        onRevertAll: { Task { await runner.revertAll(); store.refresh() } },
                        onRevert: { change in
                            Task { await runner.revert(change); store.refresh() }
                        }
                    )
                    .frame(maxHeight: 260)
                }
            }

            if let error = runner.revertError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                if runner.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Running…").foregroundStyle(.secondary)
                } else if runner.finishedSuccessfully == true {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if runner.finishedSuccessfully == false {
                    Label("Failed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                Spacer()
                if runner.isRunning {
                    Button("Stop") { runner.cancel() }
                } else if runner.hasTranscript {
                    Button("New Conversation") { runner.reset() }
                        .help("Forget this conversation and start a fresh session")
                }
                Button(runner.finishedSuccessfully == true ? "Close" : "Cancel") {
                    dismiss()
                }
                Button(runner.hasTranscript ? "Send" : "Run") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
            }
            AgentCreditLine(agent: runner.agent)
        }
        .padding(20)
        .frame(width: 560)
        .onChange(of: runner.finishedSuccessfully) { _, success in
            if success == true, !runner.lastRunWasReadOnly { store.refresh() }
        }
        .onAppear { catalogID = store.primaryCatalog?.id }
    }

    private var instructionLabel: String {
        if runner.hasTranscript {
            return "Follow up — the AI still remembers the previous turns:"
        }
        switch mode {
        case .create: return "Describe what the skill should teach the AI to do:"
        case .edit: return "Describe the change (version will be bumped automatically):"
        }
    }

    private var canRun: Bool {
        !runner.isRunning && !runner.draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func run() {
        guard let catalog = targetCatalog, store.git(for: catalog).isCloned else {
            store.lastError = GitError.notCloned.localizedDescription
            return
        }
        let text = runner.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Cleared so the box is ready for the follow-up turn.
        runner.draft = ""
        runner.run(
            instruction: text,
            cwd: CatalogStore.directory(for: catalog),
            context: context,
            ignoring: store.ignoreMatcher(for: catalog.id),
            readOnly: runner.askOnly,
            model: store.agentCLI.modelArgument
        )
    }

    /// First-turn framing: what is being created or edited, and where. Later
    /// turns resume the same session, which already knows all of it.
    private var context: String {
        switch mode {
        case .create:
            let name = skillName.trimmingCharacters(in: .whitespaces)
            let dir = folder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
            let naming = name.isEmpty
                ? "Create a new skill; choose a short, descriptive kebab-case name "
                    + "for it yourself based on the task below."
                : "Create a new skill named \"\(name)\"."
            let location = dir.isEmpty
                ? ""
                : " Place it in the subdirectory \"\(dir)\" (create it if needed), "
                    + "i.e. \(dir)/<skill-name>/SKILL.md."
            return "\(naming)\(location)"
        case .edit(let skill):
            let dir = skill.folder.isEmpty
                ? skill.path.lastPathComponent
                : "\(skill.folder)/\(skill.path.lastPathComponent)"
            return "Edit the existing skill \"\(skill.name)\" (directory: \(dir))."
        }
    }
}
