import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case catalog = "Catalog"
    case installed = "Installed"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .catalog: return "books.vertical"
        case .installed: return "checkmark.seal"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: SkillStore
    @State private var section: SidebarSection? = .catalog
    @State private var selectedSkillID: Skill.ID?
    @State private var showNewSkillSheet = false

    private var currentSection: SidebarSection { section ?? .catalog }

    private var skillsForSection: [Skill] {
        currentSection == .catalog ? store.catalog : store.installed
    }

    private var selectedSkill: Skill? {
        skillsForSection.first { $0.id == selectedSkillID }
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .badge(item == .catalog ? store.catalog.count : store.installed.count)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } content: {
            SkillListView(
                skills: skillsForSection,
                section: currentSection,
                selection: $selectedSkillID
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            // Anchored to the list column, like the sidebar toggle is to the sidebar.
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showNewSkillSheet = true
                    } label: {
                        Label("New Skill with AI", systemImage: "plus")
                    }
                    .help("Generate a new skill in the catalog using Claude Code")

                    Button {
                        Task { await store.sync() }
                    } label: {
                        if store.isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(store.isSyncing)
                    .help("Pull and push the catalog GitHub repository")
                }
            }
        } detail: {
            if let skill = selectedSkill {
                SkillDetailView(skill: skill)
                    .id(skill.id)
            } else {
                ContentUnavailableView(
                    "No Skill Selected",
                    systemImage: "sparkles",
                    description: Text("Pick a skill, or create one with AI using the + button.")
                )
            }
        }
        .sheet(isPresented: $showNewSkillSheet) {
            AISkillSheet(mode: .create)
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
        .onChange(of: section) { _, _ in selectedSkillID = nil }
        .onAppear { store.refresh() }
    }
}
