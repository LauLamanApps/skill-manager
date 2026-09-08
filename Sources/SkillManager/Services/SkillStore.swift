import Foundation
import SwiftUI

@MainActor
final class SkillStore: ObservableObject {
    @Published var catalog: [Skill] = []
    @Published var installed: [Skill] = []
    @Published var lastError: String?
    @Published var isSyncing = false
    @Published var lastSyncedCommit: String?
    /// Non-nil while a Sync sits on an unresolved rebase conflict.
    @Published var syncConflict: SyncConflict?

    @AppStorage("catalogRepoURL") var catalogRepoURL: String = ""

    static let installedDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/skills")

    static let catalogDir = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent("SkillManager/catalog")

    var git: GitService { GitService(catalogDir: Self.catalogDir) }

    // MARK: - Scanning

    /// The catalog .gitignore (plus built-in defaults) guards what the UI shows
    /// and what skill copies carry along — not just what git tracks.
    private(set) var ignoreMatcher = GitignoreMatcher(lines: GitignoreMatcher.defaultPatterns)

    func refresh() {
        ignoreMatcher = GitignoreMatcher.forCatalog(
            gitignore: Self.catalogDir.appendingPathComponent(".gitignore")
        )
        catalog = Self.scan(directory: Self.catalogDir, source: .catalog, ignoring: ignoreMatcher)
        installed = Self.scan(
            directory: Self.installedDir, source: .installed, ignoring: ignoreMatcher
        )
        Task { lastSyncedCommit = await git.lastSyncedCommit() }
    }

    /// A skill is any directory containing a SKILL.md; directories without one are
    /// treated as folders and scanned recursively. Dot-directories (.git) are skipped.
    private static func scan(
        directory: URL, source: SkillSource, ignoring: GitignoreMatcher
    ) -> [Skill] {
        var skills: [Skill] = []
        scanTree(
            directory: directory, root: directory, source: source,
            ignoring: ignoring, into: &skills
        )
        return skills.sorted {
            if $0.folder != $1.folder {
                return $0.folder.localizedCaseInsensitiveCompare($1.folder) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func scanTree(
        directory: URL, root: URL, source: SkillSource,
        ignoring: GitignoreMatcher, into skills: inout [Skill]
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  !entry.lastPathComponent.hasPrefix(".") else { continue }
            let entryRel = String(
                entry.standardizedFileURL.path
                    .dropFirst(root.standardizedFileURL.path.count)
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if ignoring.isIgnored(relativePath: entryRel) { continue }
            let skillFile = entry.appendingPathComponent("SKILL.md")
            if let content = try? String(contentsOf: skillFile, encoding: .utf8) {
                let meta = Frontmatter.parse(content)
                let folder = String(
                    directory.standardizedFileURL.path
                        .dropFirst(root.standardizedFileURL.path.count)
                ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                skills.append(Skill(
                    name: meta.name ?? entry.lastPathComponent,
                    description: meta.description ?? "",
                    version: meta.version,
                    tags: meta.tags,
                    folder: folder,
                    path: entry,
                    source: source,
                    issues: SkillHealth.check(content: content),
                    bodyText: Frontmatter.split(content).body
                ))
            } else {
                scanTree(
                    directory: entry, root: root, source: source,
                    ignoring: ignoring, into: &skills
                )
            }
        }
    }

    /// All tags across the catalog, unique, alphabetical.
    var catalogTags: [String] {
        Array(Set(catalog.flatMap(\.tags)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Lookups

    func installedSkill(named name: String) -> Skill? {
        installed.first { $0.name == name }
    }

    func catalogSkill(named name: String) -> Skill? {
        catalog.first { $0.name == name }
    }

    /// Catalog has a strictly newer version than the installed copy.
    func updateAvailable(for skill: Skill) -> Bool {
        let name = skill.name
        guard let cat = catalogSkill(named: name), let inst = installedSkill(named: name),
              let catVersion = cat.version else { return false }
        guard let instVersion = inst.version else { return true }
        return compareVersions(instVersion, catVersion) == .orderedAscending
    }

    // MARK: - Install / uninstall

    func install(_ skill: Skill) {
        do {
            try performInstall(skill)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func performInstall(_ skill: Skill) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.installedDir, withIntermediateDirectories: true)
        let dest = Self.installedDir.appendingPathComponent(skill.path.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: skill.path, to: dest)
        pruneIgnored(at: dest)
    }

    /// Removes gitignored junk (e.g. __pycache__) from a freshly copied skill.
    private func pruneIgnored(at root: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        var doomed: [URL] = []
        for case let url as URL in enumerator {
            let rel = String(
                url.standardizedFileURL.path
                    .dropFirst(root.standardizedFileURL.path.count)
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if ignoreMatcher.isIgnored(relativePath: rel) {
                doomed.append(url)
                enumerator.skipDescendants()
            }
        }
        for url in doomed {
            try? fm.removeItem(at: url)
        }
    }

    /// Rewrites the tags in a skill's SKILL.md frontmatter. Touches only the
    /// frontmatter block, so an open editor's unsaved body edits stay intact.
    func setTags(_ skill: Skill, tags: [String]) {
        do {
            try performSetTags(skill, tags: tags)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func performSetTags(_ skill: Skill, tags: [String]) throws {
        let raw = try String(contentsOf: skill.skillFile, encoding: .utf8)
        let updated = Frontmatter.settingTags(in: raw, tags: tags)
        if updated != raw {
            try updated.write(to: skill.skillFile, atomically: true, encoding: .utf8)
        }
    }

    /// Copies an installed skill into the catalog (optionally into a subfolder) and
    /// ensures both copies carry a version so update tracking works from now on.
    func addToCatalog(_ skill: Skill, folder: String = "") {
        do {
            let fm = FileManager.default
            let cleanFolder = folder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
            var destDir = Self.catalogDir
            if !cleanFolder.isEmpty {
                destDir.appendPathComponent(cleanFolder)
            }
            let dest = destDir.appendingPathComponent(skill.path.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                lastError = "“\(skill.path.lastPathComponent)” already exists in the catalog."
                return
            }
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            try fm.copyItem(at: skill.path, to: dest)
            pruneIgnored(at: dest)

            let catalogFile = dest.appendingPathComponent("SKILL.md")
            if let content = try? String(contentsOf: catalogFile, encoding: .utf8) {
                let versioned = Frontmatter.ensuringVersion(in: content, name: skill.name)
                if versioned != content {
                    try versioned.write(to: catalogFile, atomically: true, encoding: .utf8)
                    // Mirror into the installed copy so it doesn't immediately
                    // show as outdated against the catalog's new version.
                    try versioned.write(to: skill.skillFile, atomically: true, encoding: .utf8)
                }
            }
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func uninstall(_ skill: Skill) {
        do {
            var trashURL: NSURL?
            try FileManager.default.trashItem(at: skill.path, resultingItemURL: &trashURL)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Trials

    /// Opens a Terminal running Claude Code with `skill` loaded ad hoc, so it
    /// can be exercised before committing to an install. See `SkillTrial`.
    func tryIt(_ skill: Skill, model: String? = nil) async {
        do {
            try await SkillTrial.start(skill, model: model)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Bulk operations

    /// Installs several catalog skills in one go: same per-skill work as
    /// `install(_:)`, but a single `refresh()` at the end instead of one per
    /// item. A failing skill doesn't abort the rest — every error is collected
    /// and reported together.
    func install(_ skills: [Skill]) {
        runBatch(skills) { try performInstall($0) }
    }

    func uninstall(_ skills: [Skill]) {
        runBatch(skills) { skill in
            var trashURL: NSURL?
            try FileManager.default.trashItem(at: skill.path, resultingItemURL: &trashURL)
        }
    }

    /// Appends `tag` to every skill that doesn't carry it yet; skills that
    /// already have it are left untouched.
    func addTag(_ tag: String, to skills: [Skill]) {
        let clean = tag.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        runBatch(skills) { skill in
            guard !skill.tags.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame })
            else { return }
            try performSetTags(skill, tags: skill.tags + [clean])
        }
    }

    /// Runs `body` for each skill, keeping going after a failure, then refreshes
    /// once. Failures surface as a single error listing the skills that broke.
    private func runBatch(_ skills: [Skill], _ body: (Skill) throws -> Void) {
        var failures: [String] = []
        for skill in skills {
            do {
                try body(skill)
            } catch {
                failures.append("\(skill.name): \(error.localizedDescription)")
            }
        }
        refresh()
        if !failures.isEmpty {
            lastError = failures.joined(separator: "\n")
        }
    }

    // MARK: - Git sync

    func sync() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            if !git.isCloned {
                try await git.clone(from: catalogRepoURL)
                git.ensureGitignore()
            } else {
                git.ensureGitignore()
                // Commit before pulling — rebase refuses on a dirty worktree.
                try await git.commitLocalChanges(message: "Update skills via Skill Manager")
                if await git.remoteHasCommits() {
                    try await git.pull()
                }
                try await git.push()
            }
            refresh()
        } catch {
            report(error)
        }
    }

    /// Applies the user's per-file choices to the stopped rebase and finishes
    /// the sync. Another conflicting commit further along the rebase re-opens
    /// the sheet with the new files instead of erroring out.
    func resolveSyncConflict(_ choices: [String: ConflictResolution]) async {
        isSyncing = true
        defer { isSyncing = false }
        syncConflict = nil
        do {
            try await git.resolveConflicts(choices)
            try await git.push()
            refresh()
        } catch {
            report(error)
        }
    }

    /// Drops the rebase — the catalog goes back to its pre-sync state.
    func cancelSyncConflict() async {
        syncConflict = nil
        await git.abortRebase()
        refresh()
    }

    /// A conflict opens the resolution sheet; everything else is a plain error.
    private func report(_ error: Error) {
        if case GitError.conflict(let files) = error, !files.isEmpty {
            syncConflict = SyncConflict(files: files)
        } else {
            lastError = error.localizedDescription
        }
    }

    func cloneCatalog() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await git.clone(from: catalogRepoURL)
            git.ensureGitignore()
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

/// The files a Sync stopped on, as one presentable unit for `sheet(item:)`.
struct SyncConflict: Identifiable {
    let id = UUID()
    let files: [String]
}
