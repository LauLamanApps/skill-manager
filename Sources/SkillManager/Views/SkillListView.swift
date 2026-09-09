import AppKit
import SwiftUI

struct SkillListView: View {
    @EnvironmentObject var store: SkillStore
    @Environment(\.openWindow) private var openWindow
    let skills: [Skill]
    let section: SidebarSection
    @Binding var selection: Set<Skill.ID>

    @State private var searchText = ""
    @State private var activeTag: String?
    @State private var activeCatalogID: UUID?
    @State private var showBulkTagSheet = false
    @State private var confirmBulkUninstall = false

    /// The selection acts on every picked skill, including ones the current
    /// search/tag filter hides — filtering is a view, not a deselection.
    private var selectedSkills: [Skill] {
        skills.filter { selection.contains($0.id) }
    }

    private var allTags: [String] {
        Array(Set(skills.flatMap(\.tags)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Catalogs actually represented among `skills`, in configured order — the
    /// filter only ever offers choices that would narrow the current list.
    private var presentCatalogs: [Catalog] {
        let ids = Set(skills.compactMap(\.catalogID))
        return store.catalogs.filter { ids.contains($0.id) }
    }

    private var filteredSkills: [Skill] {
        skills.filter { skill in
            if let tag = activeTag, !skill.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                return false
            }
            if let activeCatalogID, skill.catalogID != activeCatalogID {
                return false
            }
            let query = searchText.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return true }
            return skill.name.localizedCaseInsensitiveContains(query)
                || skill.description.localizedCaseInsensitiveContains(query)
                || skill.tags.contains { $0.localizedCaseInsensitiveContains(query) }
                || skill.folder.localizedCaseInsensitiveContains(query)
                || skill.bodyText.localizedCaseInsensitiveContains(query)
        }
    }

    /// Folder → skills, folders alphabetical with root ("") first. Skills arrive
    /// pre-sorted from the store, and grouping keeps that order per folder.
    private var groupedSkills: [(folder: String, skills: [Skill])] {
        let groups = Dictionary(grouping: filteredSkills, by: \.folder)
        return groups.keys
            .sorted {
                if $0.isEmpty != $1.isEmpty { return $0.isEmpty }
                return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            .map { (folder: $0, skills: groups[$0]!) }
    }

    var body: some View {
        Group {
            if skills.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    searchField
                    Divider()
                    if !allTags.isEmpty {
                        tagBar
                        Divider()
                    }
                    if presentCatalogs.count > 1 {
                        catalogFilterBar
                        Divider()
                    }
                    if selectedSkills.count > 1 {
                        bulkBar
                        Divider()
                    }
                    if filteredSkills.isEmpty {
                        ContentUnavailableView.search
                    } else {
                        skillGrid
                    }
                }
            }
        }
        .navigationTitle(section.rawValue)
        .onChange(of: presentCatalogs) { _, new in
            if let id = activeCatalogID, !new.contains(where: { $0.id == id }) {
                activeCatalogID = nil
            }
        }
        .sheet(isPresented: $showBulkTagSheet) {
            BulkTagSheet(skills: selectedSkills, existingTags: allTags)
        }
        .confirmationDialog(
            "Uninstall \(selectedSkills.count) skills?",
            isPresented: $confirmBulkUninstall,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                store.uninstall(selectedSkills)
                selection.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their folders are removed from ~/.claude/skills. This can't be undone.")
        }
    }

    /// Appears once two or more rows are picked; every action is a batch of the
    /// same single-skill store call, with one refresh at the end.
    private var bulkBar: some View {
        HStack(spacing: 8) {
            Text("\(selectedSkills.count) selected")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if section == .catalog {
                InstallButton(skills: selectedSkills, title: "Install") {
                    selection.removeAll()
                }
                .help("Install or update all selected skills")
            }
            Button {
                showBulkTagSheet = true
            } label: {
                Label("Tag", systemImage: "tag")
            }
            .help("Add a tag to all selected skills")
            if section == .installed {
                Button(role: .destructive) {
                    confirmBulkUninstall = true
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
                .help("Remove all selected skills from ~/.claude/skills")
            }
            Button {
                selection.removeAll()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear selection")
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
    }

    /// Cards flow as wide as the window allows; the bounds keep them readable
    /// on a narrow window without stretching into banners on a wide one.
    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 12, alignment: .top)]

    private var skillGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(groupedSkills, id: \.folder) { group in
                    // A single unnamed folder is the whole list — no header needed.
                    if !(group.folder.isEmpty && groupedSkills.count == 1) {
                        Text(group.folder.isEmpty ? "General" : group.folder)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(group.skills) { skill in
                            SkillCard(
                                skill: skill,
                                section: section,
                                isSelected: selection.contains(skill.id),
                                onOpen: { open(skill) }
                            )
                            // The double-click handler is declared first so it
                            // gets the chance to claim the second click.
                            .onTapGesture(count: 2) { open(skill) }
                            .onTapGesture { select(skill) }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Plain click replaces the selection, ⌘-click toggles one card — the same
    /// semantics `List` gives for free, which a grid has to spell out.
    private func select(_ skill: Skill) {
        guard NSEvent.modifierFlags.contains(.command) else {
            selection = [skill.id]
            return
        }
        if selection.contains(skill.id) {
            selection.remove(skill.id)
        } else {
            selection.insert(skill.id)
        }
    }

    /// Opens the skill's editing window. Passing the id as the window value
    /// means a skill that is already open is brought forward, not duplicated.
    private func open(_ skill: Skill) {
        selection = [skill.id]
        openWindow(id: SkillWindow.id, value: skill.id)
    }

    /// Lives in the list column (not the window toolbar) so the open inspector
    /// can never overlap it.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search skills", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }

    private var tagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(allTags, id: \.self) { tag in
                    let isActive = activeTag?.caseInsensitiveCompare(tag) == .orderedSame
                    Button {
                        activeTag = isActive ? nil : tag
                    } label: {
                        Text(tag)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                isActive ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var catalogFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                catalogChip(id: nil, label: "All")
                ForEach(presentCatalogs) { cat in
                    catalogChip(id: cat.id, label: cat.name)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func catalogChip(id: UUID?, label: String) -> some View {
        let isActive = activeCatalogID == id
        return Button {
            activeCatalogID = id
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    isActive ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15),
                    in: Capsule()
                )
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
        if section == .catalog {
            if store.catalogs.isEmpty {
                ContentUnavailableView(
                    "No Catalog Configured",
                    systemImage: "books.vertical",
                    description: Text("Add a catalog in Settings to get started.")
                )
            } else if !store.hasClonedCatalog {
                ContentUnavailableView(
                    "Catalog Not Synced Yet",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Hit Sync to clone the configured catalog(s).")
                )
            } else {
                ContentUnavailableView(
                    "Catalog Is Empty",
                    systemImage: "books.vertical",
                    description: Text("No skills in the catalog yet. Create one with the + button.")
                )
            }
        } else {
            ContentUnavailableView(
                "No Skills Installed",
                systemImage: "checkmark.seal",
                description: Text("Install skills from the catalog. They land in ~/.claude/skills.")
            )
        }
    }
}

struct SkillCard: View {
    @EnvironmentObject var store: SkillStore
    let skill: Skill
    let section: SidebarSection
    let isSelected: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(skill.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                healthIcon
                Spacer(minLength: 4)
                if let version = skill.version {
                    Text("v\(version)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // Two fixed lines, so cards in a row keep the same rhythm whether a
            // description is one word or a paragraph.
            Text(skill.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !skill.tags.isEmpty {
                Label(skill.tags.joined(separator: " · "), systemImage: "tag")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                catalogBadge
                statusBadge
                Spacer(minLength: 0)
                if section == .catalog {
                    InstallButton(
                        skills: [skill],
                        title: store.installedSkill(named: skill.name) == nil ? "Install" : "Update"
                    )
                    .controlSize(.small)
                    .labelStyle(.titleOnly)
                }
            }
        }
        .padding(12)
        .frame(minHeight: 132, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.gray.opacity(0.25),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            // Double-click does the same; the item is what makes that discoverable.
            Button {
                onOpen()
            } label: {
                Label("Open in Window", systemImage: "macwindow")
            }
            if section == .catalog {
                Divider()
                if store.canTryIt {
                    Button {
                        Task { await store.tryIt(skill) }
                    } label: {
                        Label("Try it", systemImage: "play.circle")
                    }
                }
                InstallButton(
                    skills: [skill],
                    title: store.installedSkill(named: skill.name) == nil ? "Install" : "Update"
                )
            }
        }
    }

    /// Hint only — hover for the list of what's missing, fix it in the editor.
    @ViewBuilder
    private var healthIcon: some View {
        if !skill.issues.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(skill.issues.map(\.label).joined(separator: "\n"))
        }
    }

    /// Which catalog this card came from — only worth showing once the merged
    /// list actually spans more than one.
    @ViewBuilder
    private var catalogBadge: some View {
        if section == .catalog, store.catalogs.count > 1,
           let name = store.catalog(withID: skill.catalogID)?.name {
            Text(name)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if section == .catalog {
            if let installed = store.installedSkill(named: skill.name) {
                if store.updateAvailable(for: skill) {
                    badge("Update \(installed.version.map { "v\($0)" } ?? "")", .orange)
                } else {
                    badge("Installed", .green)
                }
            }
        } else if store.updateAvailable(for: skill) {
            badge("Update available", .orange)
        } else if store.catalogSkill(named: skill.name) == nil {
            badge("Not in catalog", .gray)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .lineLimit(1)
    }
}


/// Adds one tag to a whole selection at once. Existing tags of each skill are
/// kept; a skill that already carries the tag is skipped by the store.
struct BulkTagSheet: View {
    @EnvironmentObject var store: SkillStore
    @Environment(\.dismiss) private var dismiss
    let skills: [Skill]
    let existingTags: [String]

    @State private var tag = ""

    private var cleanTag: String { tag.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tag \(skills.count) Skills").font(.title3.bold())
            Text("The tag is appended to each skill's frontmatter. Skills that already have it stay unchanged.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Tag", text: $tag)
                .textFieldStyle(.roundedBorder)
                .onSubmit(apply)
            if !existingTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(existingTags, id: \.self) { existing in
                            Button {
                                tag = existing
                            } label: {
                                Text(existing)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.gray.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add Tag", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleanTag.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func apply() {
        guard !cleanTag.isEmpty else { return }
        store.addTag(cleanTag, to: skills)
        dismiss()
    }
}
