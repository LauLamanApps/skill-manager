import SwiftUI

/// Shown when Sync stops on a rebase conflict. Resolution is per file and
/// whole-file — keep the local version or the remote one. No manual merge
/// editor; anything finer belongs in a real git client.
struct SyncConflictSheet: View {
    @EnvironmentObject var store: SkillStore
    @Environment(\.dismiss) private var dismiss

    let conflict: SyncConflict

    @State private var choices: [String: ConflictResolution] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync Conflict — \(conflict.catalogName)").font(.title3.bold())
            Text(
                "\(conflict.files.count) file(s) in “\(conflict.catalogName)” changed both here "
                    + "and on the remote. Pick which version wins for each — the other one is "
                    + "discarded."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("All Local") { setAll(.keepLocal) }
                Button("All Remote") { setAll(.keepRemote) }
            }
            .controlSize(.small)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(conflict.files, id: \.self) { file in
                        HStack(spacing: 12) {
                            Text(file)
                                .font(.callout)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(file)
                            Picker("", selection: binding(for: file)) {
                                ForEach(ConflictResolution.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 240)

            HStack {
                Spacer()
                Button("Cancel Sync") {
                    Task { await store.cancelSyncConflict() }
                    dismiss()
                }
                Button("Resolve & Continue") {
                    let picked = choices
                    Task { await store.resolveSyncConflict(picked) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // Default to the user's own edits — the safer surprise of the two.
            for file in conflict.files where choices[file] == nil {
                choices[file] = .keepLocal
            }
        }
    }

    private func binding(for file: String) -> Binding<ConflictResolution> {
        Binding(
            get: { choices[file] ?? .keepLocal },
            set: { choices[file] = $0 }
        )
    }

    private func setAll(_ resolution: ConflictResolution) {
        for file in conflict.files { choices[file] = resolution }
    }
}
