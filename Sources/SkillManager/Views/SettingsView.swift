import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: SkillStore
    @EnvironmentObject var updateController: UpdateController
    @AppStorage("catalogRepoURL") private var catalogRepoURL: String = ""
    @AppStorage("claudeModel") private var claudeModel: String = ""
    @State private var claudeStatus: String?
    @State private var checkedClaude = false

    private static let currentVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

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
                Picker("Model", selection: $claudeModel) {
                    Text("Default").tag("")
                    Text("Haiku").tag("haiku")
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                }
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

            Section("Updates") {
                LabeledContent("Version", value: Self.currentVersion)
                LabeledContent("Last checked") {
                    if let lastChecked = updateController.lastUpdateCheck {
                        Text(lastChecked, format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Status") { updateStatusView }
                HStack {
                    Button("Check for Updates") {
                        Task { await updateController.checkForUpdates() }
                    }
                    .disabled(isCheckingForUpdates)
                    if isCheckingForUpdates { ProgressView().controlSize(.small) }
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

    private var isCheckingForUpdates: Bool {
        if case .checking = updateController.state { return true }
        return false
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateController.state {
        case .idle:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            Text("Checking…").foregroundStyle(.secondary)
        case .upToDate:
            Text("Up to date").foregroundStyle(.green)
        case .available(let release):
            HStack {
                Text("\(release.tagName) available").foregroundStyle(.orange)
                Button("Download") { updateController.downloadUpdate() }
            }
        case .downloading(let progress):
            HStack {
                ProgressView(value: progress).frame(width: 120)
                Text("\(Int(progress * 100))%").foregroundStyle(.secondary)
            }
        case .readyToInstall:
            Button("Install and Relaunch") { updateController.installUpdate() }
        case .installing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
            }
        case .manualInstall(let volume):
            Text("Cannot replace the app in place. Drag Skill Manager from \(volume) over your copy.")
                .foregroundStyle(.orange)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }
}
