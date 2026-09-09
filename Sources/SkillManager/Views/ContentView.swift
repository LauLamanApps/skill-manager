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
    @EnvironmentObject var chatSessions: ChatSessionStore
    @EnvironmentObject var updateController: UpdateController
    @State private var section: SidebarSection? = .catalog
    @State private var selectedSkillIDs: Set<Skill.ID> = []
    @State private var showNewSkillSheet = false

    private var isCheckingForUpdates: Bool {
        if case .checking = updateController.state { return true }
        return false
    }

    private var currentSection: SidebarSection { section ?? .catalog }

    private var skillsForSection: [Skill] {
        currentSection == .catalog ? store.catalog : store.installed
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .badge(item == .catalog ? store.catalog.count : store.installed.count)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            SkillListView(
                skills: skillsForSection,
                section: currentSection,
                selection: $selectedSkillIDs
            )
            // Anchored to the grid column, like the sidebar toggle is to the sidebar.
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showNewSkillSheet = true
                    } label: {
                        Label("New Skill with AI", systemImage: "plus")
                    }
                    .help("Generate a new skill in the catalog using AI")

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
        }
        .sheet(isPresented: $showNewSkillSheet) {
            AISkillSheet(runner: chatSessions.runner(for: .newSkill), mode: .create)
        }
        .sheet(item: $store.syncConflict) { conflict in
            SyncConflictSheet(conflict: conflict)
        }
        .sheet(isPresented: Binding(get: { isCheckingForUpdates }, set: { _ in })) {
            UpdateCheckModal()
        }
        .sheet(isPresented: Binding(
            get: { updateController.pendingInstallPrompt != nil },
            set: { if !$0 { updateController.pendingInstallPrompt = nil } }
        )) {
            if let release = updateController.pendingInstallPrompt {
                UpdateAvailableSheet(
                    release: release,
                    onInstall: {
                        updateController.installNow()
                        updateController.pendingInstallPrompt = nil
                    },
                    onLater: {
                        updateController.pendingInstallPrompt = nil
                    }
                )
            }
        }
        .alert(
            "Check for Updates",
            isPresented: Binding(
                get: { updateController.manualCheckFeedback != nil },
                set: { if !$0 { updateController.manualCheckFeedback = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(updateController.manualCheckFeedback ?? "")
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
        .onChange(of: section) { _, _ in selectedSkillIDs = [] }
        .onAppear { store.refresh() }
    }
}
