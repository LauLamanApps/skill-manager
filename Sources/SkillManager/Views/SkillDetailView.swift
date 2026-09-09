import AppKit
import SwiftUI

struct SkillDetailView: View {
    @EnvironmentObject var store: SkillStore
    @EnvironmentObject var chatSessions: ChatSessionStore
    let skill: Skill

    @State private var content: String = ""
    @State private var savedContent: String = ""
    @State private var frontmatter: String = ""
    @State private var newTag: String = ""
    @State private var showSaveSheet = false
    @State private var files: [String] = ["SKILL.md"]
    @State private var selectedFile = "SKILL.md"
    @State private var isBinaryFile = false
    @State private var editorLanguage: CodeLanguage = .markdown
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showChat = true
    @State private var chatWidth: CGFloat = 320
    /// Width when the current drag began — `DragGesture` reports translation
    /// from the start of the drag, so applying it to the live width compounds.
    @State private var chatWidthAtDragStart: CGFloat?
    @State private var showAISheet = false
    @State private var showAddToCatalogSheet = false

    private var isDirty: Bool { content != savedContent }

    /// Drives the header's fallbacks: source label and description live in the
    /// panel, so they move into the header while the panel is collapsed.
    private var showInspector: Bool { columnVisibility != .detailOnly }

    /// "Catalog" / "Installed" alone once meant a single, implicit catalog.
    /// With several configured, the pill names which one.
    private var sourceLabel: String {
        let base = skill.source == .catalog ? "Catalog" : "Installed"
        guard let name = store.catalog(withID: skill.catalogID)?.name else { return base }
        return "\(base) · \(name)"
    }

    /// Outlives this view, so the conversation survives switching skills.
    private var chatRunner: ClaudeRunner { chatSessions.runner(for: .detail(skill.id)) }

    var body: some View {
        // A split view rather than an `.inspector`, so the panel sits on the
        // leading edge like the sidebars of the main and settings windows — and
        // the standard sidebar toggle comes with it.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SkillInspectorView(
                skill: skill,
                files: files,
                isDirty: isDirty,
                selectedFile: $selectedFile,
                onSelectFile: loadFile
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            // The chat is a pane inside the detail column, not an `.inspector`.
            // An inspector has to find its width somewhere: AppKit takes it from
            // the sidebar (which visibly slides out) and from the toolbar's
            // middle section (which then shows an overflow chevron). A pane
            // leaves the detail column's own width untouched, so neither can
            // happen — only the editor beside it gives way.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    Divider()
                    if isBinaryFile {
                        ContentUnavailableView(
                            "Binary File",
                            systemImage: "doc",
                            description: Text("“\(selectedFile)” can't be edited here.")
                        )
                    } else {
                        CodeEditorView(text: $content, language: editorLanguage)
                    }
                }
                .frame(maxWidth: .infinity)

                if showChat {
                    // Handle and panel travel as one view. As siblings the
                    // handle carries no transition of its own, so it stands
                    // still while the panel slides and only blinks out once
                    // the panel is gone.
                    HStack(spacing: 0) {
                        chatResizer
                        SkillChatPanel(
                            runner: chatRunner,
                            skill: skill,
                            isDirty: isDirty,
                            onFilesChanged: reloadFromDisk
                        )
                        .frame(width: chatWidth)
                        .background(.background.secondary)
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            .clipped()
            .animation(.easeInOut(duration: 0.22), value: showChat)
            // The toolbar and title hang off the detail column, not off the
            // split view. Attached further out, AppKit gives the window one
            // unified toolbar spanning every column, and the panels start below
            // it instead of running the full height.
            .toolbar {
                ToolbarItemGroup {
                    Button("Save") { showSaveSheet = true }
                        .disabled(!isDirty)
                        .keyboardShortcut("s")

                    Button {
                        showAISheet = true
                    } label: {
                        Label("Edit with AI", systemImage: "sparkles")
                    }
                    .help("Ask the AI to modify this skill")

                    actionButton
                }
                // Far right, so it sits over the panel it opens — the trailing
                // counterpart of the split view's own leading sidebar toggle.
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showChat.toggle()
                    } label: {
                        Label("Chat", systemImage: "sidebar.trailing")
                    }
                    .help("Show or hide the AI panel")
                }
            }
            .navigationTitle(skill.name)
            .navigationSubtitle(skill.version.map { "v\($0)" } ?? "")
        }
        .sheet(isPresented: $showAISheet) {
            AISkillSheet(runner: chatSessions.runner(for: .edit(skill.id)), mode: .edit(skill))
        }
        .sheet(isPresented: $showAddToCatalogSheet) {
            AddToCatalogSheet(skill: skill)
        }
        .sheet(isPresented: $showSaveSheet) {
            SaveSkillSheet(
                skill: skill,
                fileName: selectedFile,
                frontmatter: frontmatter,
                oldBody: savedContent,
                newBody: content
            ) { newFrontmatter in
                frontmatter = newFrontmatter
                savedContent = content
            }
        }
        .onAppear { load() }
    }

    /// Drag handle between editor and chat — a plain `Divider` with a wider
    /// invisible hit area, since the pane is not a split view and brings no
    /// divider of its own.
    private var chatResizer: some View {
        Divider()
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = chatWidthAtDragStart ?? chatWidth
                                if chatWidthAtDragStart == nil { chatWidthAtDragStart = chatWidth }
                                chatWidth = min(max(260, base - value.translation.width), 520)
                            }
                            .onEnded { _ in chatWidthAtDragStart = nil }
                    )
            }
    }

    /// No name or version here — the window's title and subtitle already carry
    /// both, and repeating them costs a whole row above the editor.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !skill.folder.isEmpty || !showInspector {
                HStack(spacing: 6) {
                    if !skill.folder.isEmpty {
                        Label(skill.folder, systemImage: "folder")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    // Shown in the inspector instead while it is open.
                    if !showInspector {
                        Text(sourceLabel)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            if !showInspector, !skill.description.isEmpty {
                Text(skill.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                ForEach(skill.tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text(tag)
                        Button {
                            updateTags(skill.tags.filter { $0 != tag })
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help("Remove tag")
                    }
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                }
                TextField("Add tag", text: $newTag)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(width: 70)
                    .onSubmit(addTag)
            }
            Text(skill.path.path)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionButton: some View {
        if skill.source == .catalog {
            Button {
                Task { await store.tryIt(skill) }
            } label: {
                Label("Try it", systemImage: "play.circle")
            }
            .disabled(!store.canTryIt)
            .help(store.canTryIt
                ? "Open a \(store.agentCLI.kind.displayName) session with this skill loaded, without installing it"
                : "\(store.agentCLI.kind.displayName) can't load a skill for a single session, so it can't run a trial.")

            if store.installedSkill(named: skill.name) == nil {
                InstallButton(skills: [skill], title: "Install")
            } else if store.updateAvailable(for: skill) {
                InstallButton(skills: [skill], title: "Update", systemImage: "arrow.up.circle")
            } else if store.enabledTargets.count > 1 {
                // No "Installed" status label here — it is the widest item in
                // the toolbar and pushes it into overflow once the chat panel
                // takes its width. The info panel's State row carries it, and
                // names the agents holding the skill.
                InstallButton(skills: [skill], title: "Install Into…", systemImage: "plus.circle")
            }
        } else {
            if store.catalogSkill(named: skill.name) == nil {
                Button {
                    showAddToCatalogSheet = true
                } label: {
                    Label("Add to Catalog", systemImage: "plus.rectangle.on.folder")
                }
                .help("Copy this skill into the catalog and give it a version")
            }
            Button(role: .destructive) {
                store.uninstall(skill)
            } label: {
                Label("Uninstall", systemImage: "trash")
            }
        }
    }

    private struct AddToCatalogSheet: View {
        @EnvironmentObject var store: SkillStore
        @Environment(\.dismiss) private var dismiss
        let skill: Skill

        @State private var folder = ""
        @State private var catalogID: UUID?

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add “\(skill.name)” to Catalog").font(.title3.bold())
                Text(
                    "Copies the skill into the catalog. If it has no version yet, "
                        + "it gets version 1.0.0. Use Sync to push it to GitHub."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                if store.catalogs.count > 1 {
                    Picker("Catalog:", selection: $catalogID) {
                        ForEach(store.catalogs) { catalog in
                            Text(catalog.name).tag(catalog.id as UUID?)
                        }
                    }
                }
                TextField("Catalog folder (optional, e.g. frontend or lang/php)", text: $folder)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Add to Catalog") {
                        store.addToCatalog(
                            skill, folder: folder, to: store.catalog(withID: catalogID)
                        )
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440)
            .onAppear { catalogID = store.primaryCatalog?.id }
        }
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty,
              !skill.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })
        else { return }
        newTag = ""
        updateTags(skill.tags + [tag])
    }

    private func updateTags(_ tags: [String]) {
        store.setTags(skill, tags: tags)
        // The frontmatter kept aside for Save is now stale — re-sync it from disk
        // so a later Save doesn't write the old tags back.
        if let raw = try? String(contentsOf: skill.skillFile, encoding: .utf8) {
            frontmatter = Frontmatter.split(raw).frontmatter
        }
    }

    /// The agent touched the files under the editor — pull the catalog list and
    /// the open file back in from disk.
    private func reloadFromDisk() {
        store.refresh()
        load()
    }

    private func load() {
        scanFiles()
        if !files.contains(selectedFile) { selectedFile = "SKILL.md" }
        loadFile()
    }

    /// All regular files in the skill directory (recursive, hidden files
    /// skipped), as paths relative to the skill root. SKILL.md first.
    private func scanFiles() {
        let fm = FileManager.default
        let root = skill.path.standardizedFileURL
        let ignoring = store.ignoreMatcher(for: skill)
        var found: [String] = []
        if let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile == true else { continue }
                let rel = String(url.standardizedFileURL.path.dropFirst(root.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !rel.isEmpty, !ignoring.isIgnored(relativePath: rel) else {
                    continue
                }
                found.append(rel)
            }
        }
        files = found.sorted {
            if $0 == "SKILL.md" { return true }
            if $1 == "SKILL.md" { return false }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        if files.isEmpty { files = ["SKILL.md"] }
    }

    private func loadFile() {
        let url = skill.path.appendingPathComponent(selectedFile)
        guard let data = try? Data(contentsOf: url) else {
            isBinaryFile = false
            frontmatter = ""
            content = ""
            savedContent = ""
            return
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            isBinaryFile = true
            frontmatter = ""
            content = ""
            savedContent = ""
            return
        }
        isBinaryFile = false
        if selectedFile == "SKILL.md" {
            // The header already shows the metadata; the editor shows only the
            // body. The frontmatter block is kept aside and restored on save.
            (frontmatter, content) = Frontmatter.split(raw)
        } else {
            frontmatter = ""
            content = raw
        }
        savedContent = content
        editorLanguage = selectedFile == "SKILL.md"
            ? .markdown
            : CodeLanguage.detect(fileName: selectedFile, content: raw)
    }

}
