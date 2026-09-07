import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: SkillStore
    @AppStorage("catalogRepoURL") private var catalogRepoURL: String = ""
    @State private var claudeStatus: String?
    @State private var checkedClaude = false

    var body: some View {
        Form {
            Section("Catalog Repository") {
                TextField(
                    "GitHub repo URL",
                    text: $catalogRepoURL,
                    prompt: Text("git@github.com:you/skills-catalog.git")
                )
                LabeledContent("Local clone") {
                    Text(SkillStore.catalogDir.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Status") {
                    if store.git.isCloned {
                        Text(store.lastSyncedCommit ?? "Cloned")
                            .font(.caption)
                    } else {
                        Text("Not cloned").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(store.git.isCloned ? "Pull & Push" : "Clone") {
                        Task { await store.sync() }
                    }
                    .disabled(store.isSyncing || catalogRepoURL.isEmpty)
                    if store.isSyncing { ProgressView().controlSize(.small) }
                }
            }

            Section("Installed Skills") {
                LabeledContent("Location") {
                    Text(SkillStore.installedDir.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section("Claude Code") {
                LabeledContent("CLI") {
                    if !checkedClaude {
                        ProgressView().controlSize(.small)
                    } else if let claudeStatus {
                        Text(claudeStatus)
                            .font(.caption.monospaced())
                            .foregroundStyle(.green)
                    } else {
                        Text("`claude` not found in login shell PATH")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .task {
            claudeStatus = await ClaudeRunner.checkAvailability()
            checkedClaude = true
        }
    }
}
