import SwiftUI

/// Post-run review of what Claude Code wrote to disk: one expandable unified
/// diff per touched file, with Keep and Revert.
///
/// The edits are already applied when this appears — the CLI runs with
/// `--permission-mode acceptEdits` — so this is a review-after, not a gate
/// before. Revert restores the files to their pre-run state.
struct DiffReviewView: View {
    let changes: [FileChange]
    let onKeep: () -> Void
    let onRevertAll: () -> Void
    let onRevert: (FileChange) -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(changes) { change in
                        fileSection(change)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // A single touched file is the common case — show it opened.
        .task(id: changes.map(\.id).joined(separator: "\n")) {
            if changes.count == 1, let only = changes.first { expanded = [only.id] }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(summary, systemImage: "doc.badge.gearshape")
                .font(.caption.weight(.semibold))
            Spacer()
            Button("Revert All") { onRevertAll() }
                .disabled(!changes.contains(where: \.canRevert))
                .help("Restore every file to how it was before the run")
            Button("Keep") { onKeep() }
                .help("Accept the changes and close this review")
        }
        .controlSize(.small)
    }

    private var summary: String {
        let insertions = changes.reduce(0) { $0 + $1.insertions }
        let deletions = changes.reduce(0) { $0 + $1.deletions }
        let files = "\(changes.count) file\(changes.count == 1 ? "" : "s") changed"
        guard insertions + deletions > 0 else { return files }
        return "\(files), +\(insertions) −\(deletions)"
    }

    @ViewBuilder
    private func fileSection(_ change: FileChange) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            fileRow(change)
            if expanded.contains(change.id) {
                if change.isTextDiffable {
                    ForEach(change.diff) { line in
                        diffRow(line)
                    }
                } else {
                    Text("No text diff — the file is binary or too large to snapshot.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .padding(.leading, 22)
                }
            }
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
    }

    private func fileRow(_ change: FileChange) -> some View {
        HStack(spacing: 6) {
            Button {
                if expanded.contains(change.id) {
                    expanded.remove(change.id)
                } else {
                    expanded.insert(change.id)
                }
            } label: {
                Image(systemName: expanded.contains(change.id)
                    ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            Image(systemName: icon(for: change.kind))
                .font(.caption2)
                .foregroundStyle(color(for: change.kind))
            Text(change.path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if change.insertions > 0 {
                Text("+\(change.insertions)").font(.caption2.monospaced()).foregroundStyle(.green)
            }
            if change.deletions > 0 {
                Text("−\(change.deletions)").font(.caption2.monospaced()).foregroundStyle(.red)
            }
            Spacer(minLength: 8)
            Button("Revert") { onRevert(change) }
                .controlSize(.mini)
                .disabled(!change.canRevert)
                .help(change.canRevert
                    ? "Restore this file to how it was before the run"
                    : "No pre-run copy of this file was kept — it was too large to snapshot")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func diffRow(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 30, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 30, alignment: .trailing)
                .padding(.trailing, 6)
            if line.kind == .gap {
                Text("⋯ \(line.text)")
                    .foregroundStyle(.tertiary)
            } else {
                Text(marker(for: line.kind) + line.text)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(line.kind == .context ? .secondary : .primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(background(for: line.kind))
    }

    private func marker(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .insertion: return "+ "
        case .deletion: return "- "
        case .context, .gap: return "  "
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .insertion: return .green.opacity(0.16)
        case .deletion: return .red.opacity(0.16)
        case .context, .gap: return .clear
        }
    }

    private func icon(for kind: FileChange.Kind) -> String {
        switch kind {
        case .added: return "plus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .deleted: return "minus.circle.fill"
        }
    }

    private func color(for kind: FileChange.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .modified: return .accentColor
        case .deleted: return .red
        }
    }
}
