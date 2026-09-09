import SwiftUI
import AppKit

/// Save dialog for manual skill edits: AI suggests a version bump and a change
/// summary, the user decides. Nothing is written until Save here — then the
/// file is written with the chosen version and (for catalog skills) committed
/// with the summary as message. Pushing stays with Sync.
struct SaveSkillSheet: View {
    @EnvironmentObject var store: SkillStore
    @Environment(\.dismiss) private var dismiss

    let skill: Skill
    /// Relative path of the edited file within the skill directory.
    let fileName: String
    let frontmatter: String
    let oldBody: String
    let newBody: String
    let onSaved: (String) -> Void

    @State private var bump: SemverBump = .patch
    @State private var suggestedBump: SemverBump?
    @State private var summary = ""
    @State private var isLoadingSuggestion = true
    @State private var isSaving = false
    @State private var createPR = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save “\(skill.name)”").font(.title3.bold())

            if isLoadingSuggestion {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing change with AI…").foregroundStyle(.secondary)
                }
            }

            Picker("New version:", selection: $bump) {
                ForEach([SemverBump.patch, .minor, .major], id: \.self) { kind in
                    Text(optionLabel(kind)).tag(kind)
                }
            }
            .pickerStyle(.radioGroup)

            Text("Change summary (used as commit message):")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $summary)
                .font(.body)
                .frame(minHeight: 56, maxHeight: 90)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            if skill.source == .installed {
                Text("Installed skill — the file is saved without a git commit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Create a pull request instead of committing directly", isOn: $createPR)
                if createPR {
                    Text(
                        "The change is pushed on branch “\(branchName)” and the PR page "
                            + "opens. It shows up in the catalog after merge and Sync."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            let suggestion = await VersionAdvisor.suggest(
                fileName: fileName, old: oldBody, new: newBody
            )
            bump = suggestion.bump
            suggestedBump = suggestion.bump
            if !suggestion.summary.isEmpty { summary = suggestion.summary }
            isLoadingSuggestion = false
        }
    }

    /// Branch for the PR flow: skill/<dir>-v<version>, unsafe chars dashed.
    private var branchName: String {
        let slug = String(
            skill.path.lastPathComponent.lowercased().map { char in
                char.isLetter || char.isNumber || char == "-" || char == "." ? char : "-"
            }
        )
        return "skill/\(slug)-v\(bump.apply(to: skill.version))"
    }

    private func optionLabel(_ kind: SemverBump) -> String {
        var label = "\(kind.rawValue.capitalized) — v\(kind.apply(to: skill.version))"
        if kind == suggestedBump { label += "  (suggested)" }
        return label
    }

    private func save() {
        isSaving = true
        let version = bump.apply(to: skill.version)
        Task {
            do {
                let newFrontmatter: String
                if fileName == "SKILL.md" {
                    let raw = Frontmatter.settingVersion(
                        in: frontmatter + newBody, version: version
                    )
                    try raw.write(to: skill.skillFile, atomically: true, encoding: .utf8)
                    newFrontmatter = Frontmatter.split(raw).frontmatter
                } else {
                    // Write the edited file; the version lives in SKILL.md.
                    try newBody.write(
                        to: skill.path.appendingPathComponent(fileName),
                        atomically: true, encoding: .utf8
                    )
                    let raw = (try? String(contentsOf: skill.skillFile, encoding: .utf8)) ?? ""
                    try Frontmatter.settingVersion(in: raw, version: version)
                        .write(to: skill.skillFile, atomically: true, encoding: .utf8)
                    newFrontmatter = frontmatter
                }
                // Commits land in the repo the skill was scanned from, not in
                // whichever catalog happens to be first. A skill whose catalog
                // is gone keeps the saved file — there is just no repo to
                // commit it to.
                if skill.source == .catalog, let git = store.git(forCatalogID: skill.catalogID) {
                    let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = "\(skill.name) v\(version): "
                        + (text.isEmpty ? "update skill" : text)
                    if createPR {
                        let url = try await git.createPullRequest(
                            paths: [skill.path.path],
                            branch: branchName,
                            title: message,
                            body: text.isEmpty ? message : text
                        )
                        if let url {
                            NSWorkspace.shared.open(url)
                        }
                    } else {
                        try await git.commit(paths: [skill.path.path], message: message)
                    }
                }
                store.refresh()
                onSaved(newFrontmatter)
                dismiss()
            } catch {
                store.lastError = error.localizedDescription
            }
            isSaving = false
        }
    }
}
