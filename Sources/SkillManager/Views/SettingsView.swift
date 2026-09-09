import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case catalog = "Catalogs"
    case skills = "Installed Skills"
    case agent = "Agent"
    case updates = "Updates"
    case releaseNotes = "Release Notes"
    case about = "About"

    var id: String { rawValue }

    /// About is pinned to the bottom of the sidebar, so the List skips it.
    static var mainTabs: [SettingsTab] { allCases.filter { $0 != .about } }

    var icon: String {
        switch self {
        case .catalog: "books.vertical"
        case .skills: "checkmark.seal"
        case .agent: "terminal"
        case .updates: "arrow.down.circle"
        case .releaseNotes: "doc.text"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsTab = .catalog
    /// Pinned open: Settings has nowhere useful to go with the sidebar collapsed,
    /// so the toggle is dropped and the column stays put.
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(SettingsTab.mainTabs, selection: $selection) { tab in
                Label(tab.rawValue, systemImage: tab.icon).tag(tab)
            }
            .listStyle(.sidebar)
            .hidingSidebarToggle()
            // A List lays rows out top-down at their intrinsic height, so no
            // spacer row can push About down. A bottom safe-area inset can.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarFooterRow
            }
            // Fixed, not min/ideal/max: the flexible form loses to AppKit's
            // autosaved divider position, which pinned this at 148pt. Applied
            // last so the preference is set on the column's outermost view.
            .navigationSplitViewColumnWidth(260)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selection {
                    case .catalog: CatalogsSettings()
                    case .skills: InstalledSkillsSettings()
                    case .agent: AgentSettings()
                    case .updates: UpdatesSettings()
                    case .releaseNotes: ReleaseNotesSettings()
                    case .about: AboutSettings()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(selection.rawValue)
            // A window with no toolbar gets a plain titlebar and parks the split
            // view below it. The main window's sidebar only runs full height —
            // traffic lights on the material — because its toolbar makes AppKit
            // build a unified titlebar. This claims one so Settings matches.
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Color.clear.frame(width: 1, height: 1)
                }
            }
        }
    }

    /// About lives outside the List, so it needs the sidebar row look by hand:
    /// the same leading icon, and the accent pill when it is the active tab.
    private var sidebarFooterRow: some View {
        let isSelected = selection == .about
        return Button {
            selection = .about
        } label: {
            Label(SettingsTab.about.rawValue, systemImage: SettingsTab.about.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

private struct CatalogsSettings: View {
    @EnvironmentObject var store: SkillStore
    @State private var addingCatalog = false
    @State private var renaming: Catalog?
    @State private var removing: Catalog?
    /// The row whose own Clone/Sync button is running, so only that row shows a
    /// spinner while a global Sync leaves every row busy.
    @State private var syncingCatalogID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Catalogs").font(.headline)
                if store.catalogs.isEmpty {
                    Text("No catalogs yet. Add one to clone skills from a git repository.")
                        .foregroundStyle(.secondary)
                        .font(.body)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.catalogs) { catalog in
                            row(for: catalog)
                            Divider()
                        }
                    }
                }
            }

            HStack {
                Button("Add Catalog…") { addingCatalog = true }
                Spacer()
                if store.catalogs.count > 1 {
                    Text("The first catalog is the default target for new skills.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $addingCatalog) {
            CatalogEditorSheet(mode: .add, existingURLs: store.catalogs.map(\.repoURL)) { name, url in
                guard let catalog = store.addCatalog(name: name, repoURL: url) else { return }
                Task { await sync(catalog) }
            }
        }
        .sheet(item: $renaming) { catalog in
            CatalogEditorSheet(mode: .rename(catalog), existingURLs: []) { name, _ in
                store.renameCatalog(catalog, to: name)
            }
        }
        .confirmationDialog(
            "Remove “\(removing?.name ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            if let catalog = removing {
                Button("Remove and Move Clone to Trash", role: .destructive) {
                    store.removeCatalog(catalog, trashingClone: true)
                }
                Button("Remove, Keep Clone on Disk") {
                    store.removeCatalog(catalog, trashingClone: false)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The catalog is dropped from the list. Its skills stay installed either way.")
        }
    }

    @ViewBuilder
    private func row(for catalog: Catalog) -> some View {
        let git = store.git(for: catalog)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(catalog.name)
                Text(catalog.repoURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(status(for: catalog, isCloned: git.isCloned))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(CatalogStore.directory(for: catalog).path)

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    if syncingCatalogID == catalog.id {
                        ProgressView().controlSize(.small)
                    }
                    Button(git.isCloned ? "Sync" : "Clone") {
                        Task { await sync(catalog) }
                    }
                    .disabled(store.isSyncing)
                    Menu {
                        Button("Rename…") { renaming = catalog }
                        Button("Move Up") { store.moveCatalog(catalog, by: -1) }
                            .disabled(catalog.id == store.catalogs.first?.id)
                        Button("Move Down") { store.moveCatalog(catalog, by: 1) }
                            .disabled(catalog.id == store.catalogs.last?.id)
                        Divider()
                        Button("Remove…", role: .destructive) { removing = catalog }
                    } label: {
                        // A borderless menu reserves indicator space even when
                        // hidden, so the glyph gets its own box to center in.
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func status(for catalog: Catalog, isCloned: Bool) -> String {
        guard isCloned else { return "Not cloned" }
        return store.lastSyncedCommit(for: catalog) ?? "Cloned"
    }

    private func sync(_ catalog: Catalog) async {
        syncingCatalogID = catalog.id
        await store.sync(catalog)
        syncingCatalogID = nil
    }
}

/// Add and Rename share one sheet: adding asks for both fields, renaming edits
/// the display name only — the repo URL is what the existing clone points at.
private struct CatalogEditorSheet: View {
    enum Mode {
        case add
        case rename(Catalog)
    }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    let existingURLs: [String]
    let onSave: (String, String) -> Void

    @State private var name = ""
    @State private var repoURL = ""

    private var isRename: Bool {
        if case .rename = mode { return true }
        return false
    }

    private var trimmedURL: String {
        repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        existingURLs.contains { $0.caseInsensitiveCompare(trimmedURL) == .orderedSame }
    }

    private var canSave: Bool {
        isRename
            ? !name.trimmingCharacters(in: .whitespaces).isEmpty
            : !trimmedURL.isEmpty && !isDuplicate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isRename ? "Rename Catalog" : "Add Catalog").font(.headline)
            Form {
                if !isRename {
                    TextField(
                        "Repository URL",
                        text: $repoURL,
                        prompt: Text("git@github.com:you/skills-catalog.git")
                    )
                }
                TextField("Name", text: $name, prompt: Text(namePlaceholder))
            }
            .formStyle(.columns)
            if isDuplicate {
                Text("That repository is already configured as a catalog.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isRename ? "Rename" : "Add") {
                    onSave(name, trimmedURL)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if case .rename(let catalog) = mode { name = catalog.name }
        }
    }

    /// Leaving the name empty on Add is fine — the repo name fills in for it.
    private var namePlaceholder: String {
        let derived = Catalog.repoName(from: trimmedURL)
        return derived.isEmpty ? "Catalog" : derived
    }
}

private struct InstalledSkillsSettings: View {
    @EnvironmentObject var store: SkillStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Installed Skills").font(.headline)
                Text("Skills can be installed into the agents you enable here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.agentTargets.enumerated()), id: \.element.id) { index, target in
                    if index > 0 {
                        Divider().padding(.leading, 12)
                    }
                    row(for: target)
                }
            }
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )

            if store.enabledTargets.isEmpty {
                Label(
                    "No agent is enabled — Install has nowhere to write.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func row(for target: AgentTarget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(target.kind.displayName, systemImage: target.kind.icon)
                    .font(.body.weight(.medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { target.isEnabled },
                    set: { store.setTarget(target.kind, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .scaleEffect(0.8)
            }

            HStack(spacing: 8) {
                Text(abbreviated(target.path))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseFolder(for: target) }
                    .controlSize(.small)
            }

            // Only Claude Code's location is verified; the rest ship as guesses
            // and say so rather than quietly pointing somewhere nothing reads.
            if !target.kind.hasVerifiedPath && !target.exists {
                Label(
                    "This folder doesn't exist yet — check it matches where \(target.kind.displayName) reads skills.",
                    systemImage: "questionmark.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    /// Home-relative display, so a long path stays readable in a narrow pane.
    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseFolder(for target: AgentTarget) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = target.exists
            ? target.url
            : FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Use Folder"
        panel.message = "Where should \(target.kind.displayName) read installed skills from?"
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        store.setTarget(target.kind, path: picked.path)
    }
}

private struct AgentSettings: View {
    @EnvironmentObject var store: SkillStore
    /// Version string of the configured binary, nil once a check came back
    /// empty-handed. `checked` separates "not there" from "still looking".
    @State private var version: String?
    @State private var checked = false

    private var cli: AgentCLI { store.agentCLI }

    /// Kinds the app can install into but not yet be driven by. Named rather
    /// than silently absent, so the short picker reads as a state of the app
    /// instead of an oversight.
    private var withoutRunner: [AgentCLI.Kind] {
        AgentCLI.Kind.allCases.filter { !$0.hasRunner }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent").font(.headline)
                Text("The CLI that generates, edits and trials skills.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Same label-left / value-right, divider-separated rows as the
            // Updates and About tabs, so the four settings read as one list
            // instead of four loosely stacked controls.
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Agent").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { cli.kind },
                        set: { store.setAgent(kind: $0) }
                    )) {
                        ForEach(AgentCLI.Kind.allCases.filter(\.hasRunner)) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                HStack {
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    modelControl
                }
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text("Binary").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    binaryRow
                }
                Divider()
                HStack {
                    Text("CLI").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    statusRow
                }
            }

            if !withoutRunner.isEmpty {
                Label(
                    "\(withoutRunner.map(\.displayName).joined(separator: ", ")) can receive "
                        + "installed skills, but can't drive the app yet.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        // Re-runs whenever the agent, its path — or, harmlessly, its model —
        // changes, so the status below always describes what is configured now.
        .task(id: cli) {
            checked = false
            version = await AgentRunners.active.checkAvailability()
            checked = true
        }
    }

    /// A picker when the app knows the CLI's model names, a free text field
    /// when it doesn't.
    @ViewBuilder
    private var modelControl: some View {
        let model = Binding(get: { cli.model }, set: { store.setAgent(model: $0) })
        if cli.kind.modelOptions.isEmpty {
            TextField("", text: model, prompt: Text("The CLI's default"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        } else {
            Picker("", selection: model) {
                Text("Default").tag("")
                ForEach(cli.kind.modelOptions, id: \.self) { option in
                    Text(option.capitalized).tag(option)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var binaryRow: some View {
        HStack(spacing: 8) {
            Text(cli.binaryPath ?? "Found on PATH as `\(cli.kind.binaryName)`")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .trailing)
            if cli.binaryPath != nil {
                Button("Use PATH") { store.setAgent(binaryPath: nil) }
                    .controlSize(.small)
            }
            Button("Choose…") { chooseBinary() }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            if !checked {
                ProgressView().controlSize(.small)
            } else if let version {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(version)
                    .font(.caption.monospaced())
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(cli.binaryPath == nil
                    ? "`\(cli.kind.binaryName)` not found in login shell PATH"
                    : "`\(cli.launchPath)` can't be run")
                    .foregroundStyle(.red)
            }
        }
    }

    /// Hidden files shown: CLIs installed by a version manager usually sit
    /// under a dot-directory the panel would otherwise refuse to open.
    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = cli.binaryPath
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        panel.prompt = "Use Binary"
        panel.message = "Choose the \(cli.kind.displayName) executable."
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        store.setAgent(binaryPath: picked.path)
    }
}

private struct UpdatesSettings: View {
    @EnvironmentObject var updateController: UpdateController

    private static let currentVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Updates").font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Version").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.currentVersion)
                }
                Divider()
                HStack {
                    Text("Last checked").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let lastChecked = updateController.lastUpdateCheck {
                        Text(lastChecked, format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack {
                    Text("Status").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    updateStatusView
                }
                Divider()
                HStack {
                    Button("Check for Updates") {
                        Task { await updateController.checkForUpdates(manual: true) }
                    }
                    .disabled(isCheckingForUpdates)
                    if isCheckingForUpdates { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }
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

private struct ReleaseNotesSettings: View {
    /// Parsed once for the app's lifetime: the bundled notes never change while
    /// the app runs, and every collapsed card would otherwise re-parse.
    private static let versions: [VersionNotes] = ReleaseNotes.bundled.map {
        VersionNotes(id: $0.id, title: $0.title, blocks: ReleaseNoteBlock.parse($0.body))
    }

    /// Older cards start collapsed; the newest one starts open.
    @State private var expanded: Set<String> = Self.versions.first.map { [$0.id] } ?? []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Release Notes").font(.headline)
            if Self.versions.isEmpty {
                Text("No release notes are bundled with this build.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.versions) { version in
                        card(for: version)
                    }
                }
            }
        }
    }

    private func card(for version: VersionNotes) -> some View {
        let isOpen = expanded.contains(version.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { toggle(version) }
            } label: {
                HStack {
                    Text(version.title).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(12)

            if isOpen {
                ReleaseNoteBlocksView(blocks: version.blocks)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }

    private func toggle(_ version: VersionNotes) {
        if expanded.contains(version.id) {
            expanded.remove(version.id)
        } else {
            expanded.insert(version.id)
        }
    }

    private struct VersionNotes: Identifiable {
        let id: String
        let title: String
        let blocks: [ReleaseNoteBlock]
    }
}

private struct AboutSettings: View {
    private static let currentVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    private static let currentBuild =
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 12) {
                if let icon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                }
                Text("Skill Manager").font(.title2.bold())
                Text("Version \(Self.currentVersion) (\(Self.currentBuild))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Developer").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("LauLaman Apps")
                }
                Divider()
                HStack {
                    Text("Repository").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Link("github.com/LauLamanApps/skill-manager", destination: URL(string: "https://github.com/LauLamanApps/skill-manager")!)
                        .font(.caption)
                }
            }
        }
    }
}

private extension View {
    /// `toolbar(removing:)` is macOS 15+; older systems keep the stock toggle.
    @ViewBuilder
    func hidingSidebarToggle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}
