import SwiftUI

struct SkillDetailView: View {
    @EnvironmentObject var store: SkillStore
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
    @State private var showInspector = true
    @StateObject private var chatRunner = ClaudeRunner()
    @State private var chatInput = ""
    @State private var showAISheet = false
    @State private var showAddToCatalogSheet = false

    private var isDirty: Bool { content != savedContent }

    var body: some View {
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
            Divider()
            chatPanel
        }
        .onChange(of: chatRunner.finishedSuccessfully) { _, success in
            if success == true {
                store.refresh()
                load()
            }
        }
        .inspector(isPresented: $showInspector) {
            SkillInspectorView(
                skill: skill,
                files: files,
                isDirty: isDirty,
                selectedFile: $selectedFile,
                onSelectFile: loadFile
            )
            .inspectorColumnWidth(min: 200, ideal: 240, max: 340)
        }
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
                .help("Ask Claude Code to modify this skill")

                actionButton

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the info panel")
            }
        }
        .sheet(isPresented: $showAISheet) {
            AISkillSheet(mode: .edit(skill))
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
        .navigationTitle(skill.name)
        .navigationSubtitle(skill.version.map { "v\($0)" } ?? "")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(skill.name).font(.title2.bold())
                if let version = skill.version {
                    Text("v\(version)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
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
                        Text(skill.source == .catalog ? "Catalog" : "Installed")
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
            if store.installedSkill(named: skill.name) == nil {
                Button {
                    store.install(skill)
                } label: {
                    Label("Install", systemImage: "arrow.down.circle")
                }
            } else if store.updateAvailable(for: skill) {
                Button {
                    store.install(skill)
                } label: {
                    Label("Update", systemImage: "arrow.up.circle")
                }
            } else {
                Label("Installed", systemImage: "checkmark.circle")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
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

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add “\(skill.name)” to Catalog").font(.title3.bold())
                Text(
                    "Copies the skill into the catalog. If it has no version yet, "
                        + "it gets version 1.0.0. Use Sync to push it to GitHub."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                TextField("Catalog folder (optional, e.g. frontend or lang/php)", text: $folder)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Add to Catalog") {
                        store.addToCatalog(skill, folder: folder)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440)
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

    /// Bottom panel: instruct Claude Code (headless) to manipulate this
    /// skill's files.
    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if chatRunner.isRunning || !chatRunner.output.isEmpty {
                ScrollView {
                    Text(chatRunner.output.isEmpty ? "Claude Code is working…" : chatRunner.output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    "Ask Claude to change this skill's files…",
                    text: $chatInput,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit(runChat)
                .disabled(chatRunner.isRunning)

                Button {
                    runChat()
                } label: {
                    if chatRunner.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(!canChat)
                .help("Run Claude Code on this skill's directory")
            }
            if isDirty {
                Text("Save your changes first — Claude edits the files on disk.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private var canChat: Bool {
        !chatRunner.isRunning && !isDirty
            && !chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func runChat() {
        guard canChat else { return }
        let instruction = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        chatInput = ""
        chatRunner.run(
            instruction: "Edit the existing skill \"\(skill.name)\". You are already "
                + "inside its directory — its SKILL.md is at ./SKILL.md.\n\n\(instruction)",
            cwd: skill.path
        )
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
                guard !rel.isEmpty, !store.ignoreMatcher.isIgnored(relativePath: rel) else {
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
