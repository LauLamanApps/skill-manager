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

/// Sheet that drives Claude Code headless to create or edit a skill in the catalog.
struct AISkillSheet: View {
    @EnvironmentObject var store: SkillStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = ClaudeRunner()

    let mode: AISkillMode

    @State private var skillName = ""
    @State private var folder = ""
    @State private var instruction = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.title).font(.title3.bold())

            if case .create = mode {
                TextField(
                    "Skill name (optional — leave empty to let AI pick one)",
                    text: $skillName
                )
                .textFieldStyle(.roundedBorder)
                TextField("Catalog folder (optional, e.g. frontend or lang/php)", text: $folder)
                    .textFieldStyle(.roundedBorder)
            }

            Text(instructionLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $instruction)
                .font(.body)
                .frame(minHeight: 90, maxHeight: 140)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            if runner.isRunning || !runner.output.isEmpty {
                GroupBox {
                    ScrollView {
                        HStack {
                            Text(runner.output.isEmpty ? "Claude Code is working…" : runner.output)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                }
            }

            HStack {
                if runner.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Running Claude Code…").foregroundStyle(.secondary)
                } else if runner.finishedSuccessfully == true {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if runner.finishedSuccessfully == false {
                    Label("Failed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                Spacer()
                Button(runner.finishedSuccessfully == true ? "Close" : "Cancel") {
                    dismiss()
                }
                Button("Run") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onChange(of: runner.finishedSuccessfully) { _, success in
            if success == true { store.refresh() }
        }
    }

    private var instructionLabel: String {
        switch mode {
        case .create: return "Describe what the skill should teach Claude to do:"
        case .edit: return "Describe the change (version will be bumped automatically):"
        }
    }

    private var canRun: Bool {
        !runner.isRunning && !instruction.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func run() {
        guard store.git.isCloned else {
            store.lastError = GitError.notCloned.localizedDescription
            return
        }
        let task: String
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
            task = "\(naming)\(location)\n\n\(instruction)"
        case .edit(let skill):
            let dir = skill.folder.isEmpty
                ? skill.path.lastPathComponent
                : "\(skill.folder)/\(skill.path.lastPathComponent)"
            task = "Edit the existing skill \"\(skill.name)\" "
                + "(directory: \(dir)).\n\n\(instruction)"
        }
        runner.run(instruction: task, cwd: SkillStore.catalogDir)
    }
}
