import SwiftUI

/// Leading-edge info panel: skill metadata and a clickable file tree.
struct SkillInspectorView: View {
    @EnvironmentObject var store: SkillStore
    let skill: Skill
    let files: [String]
    let isDirty: Bool
    @Binding var selectedFile: String
    let onSelectFile: () -> Void

    private enum Tab {
        case info, files
    }

    @State private var tab: Tab = .info

    var body: some View {
        VStack(spacing: 0) {
            // Collapsing is the toolbar's sidebar toggle; the panel doesn't
            // need a second control for it.
            Picker("", selection: $tab) {
                Text("Info").tag(Tab.info)
                Text("Files").tag(Tab.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch tab {
            case .info: infoTab
            case .files: fileTree
            }
        }
    }

    private var infoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                row("Version", skill.version.map { "v\($0)" } ?? "—")
                row("Source", sourceLabel)
                installedState
                row("Description", skill.description.isEmpty ? "—" : skill.description)
                health
                row("Created", format(createdAt))
                row("Modified", format(modifiedAt))
                if let installedAt {
                    row("Installed", format(installedAt))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Metadata rows

    /// "Catalog" / "Installed" alone once meant a single, implicit catalog.
    /// With several configured, the row names which one — the catalog it was
    /// scanned from, or the catalog an installed copy was installed from.
    private var sourceLabel: String {
        let base = skill.source == .catalog ? "Catalog" : "Installed"
        guard let name = store.catalog(withID: skill.catalogID)?.name else { return base }
        return "\(base) · \(name)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    /// "Installed (Claude Code)" when several agents are configured, plain
    /// "Installed" when there is only one and naming it adds nothing. With
    /// per-agent installs, a bare "Installed" would hide that the others
    /// don't have it.
    private var installedSummary: String {
        let held = store.installedTargets(for: skill.name)
        guard store.enabledTargets.count > 1, !held.isEmpty else { return "Installed" }
        let names = store.enabledTargets
            .filter { held.contains($0.kind) }
            .map(\.kind.displayName)
        return "Installed (\(names.joined(separator: ", ")))"
    }

    @ViewBuilder
    private var installedState: some View {
        let (text, color): (String, Color) = {
            if skill.source == .catalog {
                guard let installed = store.installedSkill(named: skill.name) else {
                    return ("Not installed", .secondary)
                }
                if store.updateAvailable(for: skill) {
                    return ("Update available (installed \(installed.version.map { "v\($0)" } ?? "unversioned"))", .orange)
                }
                return (installedSummary, .green)
            }
            return store.catalogSkill(named: skill.name) == nil
                ? ("Not in catalog", .secondary)
                : ("In catalog", .green)
        }()
        VStack(alignment: .leading, spacing: 2) {
            Text("State")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(color)
        }
    }

    /// Advisory SKILL.md lint (`SkillHealth`) — never blocks anything, the fix
    /// happens in the editor or via "Edit with AI".
    @ViewBuilder
    private var health: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Health")
                .font(.caption)
                .foregroundStyle(.secondary)
            if skill.issues.isEmpty {
                Label("No issues", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                ForEach(skill.issues, id: \.self) { issue in
                    VStack(alignment: .leading, spacing: 1) {
                        Label(issue.label, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Text(issue.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Dates

    private var createdAt: Date? {
        (try? skill.path.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// Newest content change across the visible files of the skill.
    private var modifiedAt: Date? {
        files.compactMap {
            (try? skill.path.appendingPathComponent($0)
                .resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }.max()
    }

    /// Creation date of the installed copy (the moment it was installed).
    private var installedAt: Date? {
        let installedPath = skill.source == .installed
            ? skill.path
            : store.installedSkill(named: skill.name)?.path
        guard let installedPath else { return nil }
        return (try? installedPath.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - File tree

    private struct FileNode: Identifiable {
        let name: String
        let path: String
        var children: [FileNode]?
        var id: String { path }
    }

    private var tree: [FileNode] {
        Self.buildTree(paths: files, prefix: "")
    }

    private static func buildTree(paths: [String], prefix: String) -> [FileNode] {
        var fileNodes: [FileNode] = []
        var subdirs: [String: [String]] = [:]
        for path in paths {
            if let slash = path.firstIndex(of: "/") {
                let dir = String(path[..<slash])
                subdirs[dir, default: []].append(String(path[path.index(after: slash)...]))
            } else {
                fileNodes.append(FileNode(name: path, path: prefix + path, children: nil))
            }
        }
        let dirNodes = subdirs.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { dir in
                FileNode(
                    name: dir,
                    path: prefix + dir,
                    children: buildTree(paths: subdirs[dir]!, prefix: prefix + dir + "/")
                )
            }
        fileNodes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return dirNodes + fileNodes
    }

    private var fileTree: some View {
        List(tree, children: \.children) { node in
            if node.children == nil {
                Button {
                    selectedFile = node.path
                    onSelectFile()
                } label: {
                    Label(node.name, systemImage: "doc.text")
                        .font(.callout)
                        .foregroundStyle(
                            node.path == selectedFile ? Color.accentColor : Color.primary
                        )
                }
                .buttonStyle(.plain)
                .disabled(isDirty && node.path != selectedFile)
                .help(isDirty && node.path != selectedFile ? "Save first to switch files" : node.path)
            } else {
                Label(node.name, systemImage: "folder")
                    .font(.callout)
            }
        }
        .listStyle(.sidebar)
    }
}
