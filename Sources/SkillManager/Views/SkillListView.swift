import SwiftUI

struct SkillListView: View {
    @EnvironmentObject var store: SkillStore
    let skills: [Skill]
    let section: SidebarSection
    @Binding var selection: Skill.ID?

    @State private var searchText = ""
    @State private var activeTag: String?

    private var allTags: [String] {
        Array(Set(skills.flatMap(\.tags)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filteredSkills: [Skill] {
        skills.filter { skill in
            if let tag = activeTag, !skill.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                return false
            }
            let query = searchText.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return true }
            return skill.name.localizedCaseInsensitiveContains(query)
                || skill.description.localizedCaseInsensitiveContains(query)
                || skill.tags.contains { $0.localizedCaseInsensitiveContains(query) }
                || skill.folder.localizedCaseInsensitiveContains(query)
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
                    if filteredSkills.isEmpty {
                        ContentUnavailableView.search
                    } else {
                        skillList
                    }
                }
            }
        }
        .navigationTitle(section.rawValue)
    }

    private var skillList: some View {
        List(selection: $selection) {
            ForEach(groupedSkills, id: \.folder) { group in
                if group.folder.isEmpty && groupedSkills.count == 1 {
                    ForEach(group.skills) { skill in
                        SkillRow(skill: skill, section: section).tag(skill.id)
                    }
                } else {
                    Section(group.folder.isEmpty ? "General" : group.folder) {
                        ForEach(group.skills) { skill in
                            SkillRow(skill: skill, section: section).tag(skill.id)
                        }
                    }
                }
            }
        }
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

    @ViewBuilder
    private var emptyState: some View {
        if section == .catalog {
            ContentUnavailableView(
                "Catalog Is Empty",
                systemImage: "books.vertical",
                description: Text(
                    store.git.isCloned
                        ? "No skills in the catalog yet. Create one with the + button."
                        : "Set the catalog repository URL in Settings, then hit Sync to clone it."
                )
            )
        } else {
            ContentUnavailableView(
                "No Skills Installed",
                systemImage: "checkmark.seal",
                description: Text("Install skills from the catalog. They land in ~/.claude/skills.")
            )
        }
    }
}

struct SkillRow: View {
    @EnvironmentObject var store: SkillStore
    let skill: Skill
    let section: SidebarSection

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.headline)
                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !skill.tags.isEmpty {
                    Label(skill.tags.joined(separator: " · "), systemImage: "tag")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let version = skill.version {
                    Text("v\(version)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                statusBadge
            }
        }
        .padding(.vertical, 4)
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
    }
}
