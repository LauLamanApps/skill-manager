import Foundation
import SwiftUI

@MainActor
final class SkillStore: ObservableObject {
    /// Every catalog's skills, merged into one list. Each skill carries the
    /// `catalogID` it was scanned from.
    @Published var catalog: [Skill] = []
    @Published var installed: [Skill] = []
    @Published var lastError: String?
    @Published var isSyncing = false
    /// Newest commit per catalog, keyed by catalog id.
    @Published private(set) var lastSyncedCommits: [UUID: String] = [:]
    /// Non-nil while a Sync sits on an unresolved rebase conflict. Only one
    /// sheet shows at a time; further conflicts wait in `queuedConflicts`.
    @Published var syncConflict: SyncConflict?
    private var queuedConflicts: [SyncConflict] = []

    /// The configured catalogs, in display order. Persisted as `catalogs.json`.
    @Published private(set) var catalogs: [Catalog] = []

    /// Where installed skills go, one entry per AI agent. Persisted as
    /// `agent-targets.json`.
    @Published private(set) var agentTargets: [AgentTarget] = []

    /// The targets an install actually writes to.
    var enabledTargets: [AgentTarget] { agentTargets.filter(\.isEnabled) }

    /// The CLI that runs skills, and the model it runs them with. Persisted as
    /// `agent-cli.json`; `AgentRunners` holds the same value for the callers
    /// that resolve a runner outside the view tree.
    @Published private(set) var agentCLI: AgentCLI = AgentRunners.configuration

    /// Which agents each installed skill was found in, keyed by skill name. A
    /// skill can be present in some targets and missing from others.
    @Published private(set) var targetsBySkillName: [String: Set<AgentTarget.Kind>] = [:]

    /// Claude Code's location, kept as the fallback for the paths that predate
    /// multiple targets.
    static let claudeCodeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/skills")

    /// First enabled target, for the callers that still assume a single
    /// destination. Falls back to Claude Code when every target is off.
    var installedDir: URL { enabledTargets.first?.url ?? Self.claudeCodeDir }

    /// Target of the write actions that don't name a catalog yet (Add to
    /// Catalog, AI-created skills). SM-64 replaces those with an explicit pick.
    var primaryCatalog: Catalog? { catalogs.first }

    /// Clone directory of the primary catalog. The fallback only applies before
    /// the first catalog exists, where it points at an empty, unscannable path.
    var catalogDir: URL {
        primaryCatalog.map(CatalogStore.directory(for:))
            ?? CatalogStore.rootDir.appendingPathComponent("catalog")
    }

    /// Git for the primary catalog — for the single-target UI that predates
    /// multiple catalogs. Anything that knows its catalog uses `git(for:)`.
    var git: GitService { GitService(catalogDir: catalogDir) }

    func git(for catalog: Catalog) -> GitService {
        GitService(catalogDir: CatalogStore.directory(for: catalog))
    }

    /// Nil when the id belongs to no configured catalog — e.g. a skill scanned
    /// from a catalog the user removed in the meantime.
    func git(forCatalogID id: UUID?) -> GitService? {
        catalog(withID: id).map(git(for:))
    }

    /// True once at least one catalog has a working copy on disk.
    var hasClonedCatalog: Bool {
        catalogs.contains { git(for: $0).isCloned }
    }

    func catalog(withID id: UUID?) -> Catalog? {
        guard let id else { return nil }
        return catalogs.first { $0.id == id }
    }

    func lastSyncedCommit(for catalog: Catalog) -> String? {
        lastSyncedCommits[catalog.id]
    }

    var lastSyncedCommit: String? {
        primaryCatalog.flatMap { lastSyncedCommits[$0.id] }
    }

    init() {
        // Runs before the first `refresh()`, so scanning already sees the
        // migrated location rather than the emptied legacy one.
        do {
            catalogs = try CatalogStore.loadOrMigrate(
                legacyRepoURL: UserDefaults.standard.string(forKey: "catalogRepoURL") ?? ""
            )
        } catch {
            lastError = error.localizedDescription
        }
        agentTargets = AgentTargetStore.load()
    }

    // MARK: - Agent CLI

    func setAgent(kind: AgentCLI.Kind) { updateAgent { $0.kind = kind } }

    /// Nil resolves the binary from the login shell PATH again.
    func setAgent(binaryPath: String?) { updateAgent { $0.binaryPath = binaryPath } }

    func setAgent(model: String) { updateAgent { $0.model = model } }

    private func updateAgent(_ change: (inout AgentCLI) -> Void) {
        change(&agentCLI)
        // Pushed before the save: a write that fails should still leave the app
        // running what the user just picked.
        AgentRunners.configuration = agentCLI
        do {
            try AgentCLIStore.save(agentCLI)
        } catch {
            lastError = "Could not save the agent settings: \(error.localizedDescription)"
        }
    }

    // MARK: - Agent targets

    func setTarget(_ kind: AgentTarget.Kind, enabled: Bool) {
        updateTarget(kind) { $0.isEnabled = enabled }
    }

    func setTarget(_ kind: AgentTarget.Kind, path: String) {
        updateTarget(kind) { $0.path = path }
    }

    private func updateTarget(_ kind: AgentTarget.Kind, _ change: (inout AgentTarget) -> Void) {
        guard let index = agentTargets.firstIndex(where: { $0.kind == kind }) else { return }
        change(&agentTargets[index])
        do {
            try AgentTargetStore.save(agentTargets)
        } catch {
            lastError = "Could not save agent targets: \(error.localizedDescription)"
        }
        refresh()
    }

    /// The enabled targets a skill is already installed into.
    func installedTargets(for skillName: String) -> Set<AgentTarget.Kind> {
        targetsBySkillName[skillName] ?? []
    }

    // MARK: - Scanning

    /// A catalog's .gitignore (plus built-in defaults) guards what the UI shows
    /// and what skill copies carry along — not just what git tracks. One matcher
    /// per catalog: one catalog's ignore rules must not hide another's skills.
    private(set) var ignoreMatchers: [UUID: GitignoreMatcher] = [:]

    /// Defaults plus every catalog's rules, for the paths that belong to no
    /// single catalog (installed skills). With one catalog this is that
    /// catalog's matcher.
    private(set) var ignoreMatcher = GitignoreMatcher(lines: GitignoreMatcher.defaultPatterns)

    func ignoreMatcher(for catalogID: UUID?) -> GitignoreMatcher {
        guard let catalogID, let matcher = ignoreMatchers[catalogID] else { return ignoreMatcher }
        return matcher
    }

    func ignoreMatcher(for skill: Skill) -> GitignoreMatcher {
        ignoreMatcher(for: skill.catalogID)
    }

    func refresh() {
        var matchers: [UUID: GitignoreMatcher] = [:]
        var combinedLines = GitignoreMatcher.defaultPatterns
        var scanned: [Skill] = []
        for entry in catalogs {
            let dir = CatalogStore.directory(for: entry)
            let gitignore = dir.appendingPathComponent(".gitignore")
            let matcher = GitignoreMatcher.forCatalog(gitignore: gitignore)
            matchers[entry.id] = matcher
            if let content = try? String(contentsOf: gitignore, encoding: .utf8) {
                combinedLines += content.components(separatedBy: "\n")
            }
            scanned += Self.scan(
                directory: dir, source: .catalog, catalogID: entry.id, ignoring: matcher
            )
        }
        ignoreMatchers = matchers
        ignoreMatcher = GitignoreMatcher(lines: combinedLines)

        var order: [UUID: Int] = [:]
        for (index, entry) in catalogs.enumerated() { order[entry.id] = index }
        catalog = Self.sorted(scanned, catalogOrder: order)

        // One row per skill name even when several agents hold a copy; the
        // agents it was found in travel alongside in `targetsBySkillName`.
        var seen: Set<String> = []
        var merged: [Skill] = []
        var byName: [String: Set<AgentTarget.Kind>] = [:]
        for target in enabledTargets {
            let found = Self.scan(
                directory: target.url, source: .installed, catalogID: nil,
                ignoring: ignoreMatcher
            )
            for skill in found {
                byName[skill.name, default: []].insert(target.kind)
                if seen.insert(skill.name).inserted { merged.append(skill) }
            }
        }
        installed = merged
        targetsBySkillName = byName
        Task { await refreshLastSyncedCommits() }
    }

    private func refreshLastSyncedCommits() async {
        var commits: [UUID: String] = [:]
        for entry in catalogs {
            commits[entry.id] = await git(for: entry).lastSyncedCommit()
        }
        lastSyncedCommits = commits
    }

    /// A skill is any directory containing a SKILL.md; directories without one are
    /// treated as folders and scanned recursively. Dot-directories (.git) are skipped.
    private static func scan(
        directory: URL, source: SkillSource, catalogID: UUID?, ignoring: GitignoreMatcher
    ) -> [Skill] {
        var skills: [Skill] = []
        scanTree(
            directory: directory, root: directory, source: source, catalogID: catalogID,
            ignoring: ignoring, into: &skills
        )
        return sorted(skills)
    }

    /// Folder, then name — so the same skill name from two catalogs lands on
    /// adjacent rows. `catalogOrder` breaks that tie by catalog position, which
    /// keeps the merged list stable across refreshes.
    private static func sorted(_ skills: [Skill], catalogOrder: [UUID: Int] = [:]) -> [Skill] {
        skills.sorted {
            if $0.folder != $1.folder {
                return $0.folder.localizedCaseInsensitiveCompare($1.folder) == .orderedAscending
            }
            if $0.name != $1.name {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            let lhs = $0.catalogID.flatMap { catalogOrder[$0] } ?? Int.max
            let rhs = $1.catalogID.flatMap { catalogOrder[$0] } ?? Int.max
            return lhs < rhs
        }
    }

    private static func scanTree(
        directory: URL, root: URL, source: SkillSource, catalogID: UUID?,
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
                // Installed copies carry their origin catalog in the
                // frontmatter marker rather than the scan's own `catalogID`
                // (nil — installed skills aren't scanned per-catalog).
                let origin = source == .installed ? meta.originCatalogID : catalogID
                skills.append(Skill(
                    name: meta.name ?? entry.lastPathComponent,
                    description: meta.description ?? "",
                    version: meta.version,
                    tags: meta.tags,
                    folder: folder,
                    path: entry,
                    source: source,
                    catalogID: origin,
                    issues: SkillHealth.check(content: content),
                    bodyText: Frontmatter.split(content).body
                ))
            } else {
                scanTree(
                    directory: entry, root: root, source: source, catalogID: catalogID,
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

    /// The catalog skill `name` that originated from `catalogID`. With no
    /// origin (installed copy predates origin tracking) falls back to a
    /// name-only match, same as the legacy single-catalog behaviour.
    private func catalogSkill(named name: String, originatingFrom catalogID: UUID?) -> Skill? {
        guard let catalogID else { return catalogSkill(named: name) }
        return catalog.first { $0.name == name && $0.catalogID == catalogID }
    }

    /// The installed copy of `name` that was installed from `catalogID`.
    /// A copy with no origin marker (predates origin tracking) matches
    /// regardless of `catalogID`, same as the legacy single-catalog behaviour;
    /// a copy with a marker for a *different* catalog is not a match — it
    /// belongs to another catalog's row.
    private func installedSkill(named name: String, installedFrom catalogID: UUID?) -> Skill? {
        guard let inst = installedSkill(named: name) else { return nil }
        guard let origin = inst.catalogID else { return inst }
        return origin == catalogID ? inst : nil
    }

    /// Catalog has a strictly newer version than the installed copy. Compares
    /// against the catalog the installed copy actually came from (recorded on
    /// install as a `catalog:` frontmatter marker), not an arbitrary catalog
    /// that happens to share the skill's name — duplicate names across
    /// catalogs are allowed.
    func updateAvailable(for skill: Skill) -> Bool {
        let inst: Skill?
        let cat: Skill?
        if skill.source == .installed {
            inst = skill
            cat = catalogSkill(named: skill.name, originatingFrom: skill.catalogID)
        } else {
            cat = skill
            inst = installedSkill(named: skill.name, installedFrom: skill.catalogID)
        }
        guard let inst, let cat, let catVersion = cat.version else { return false }
        guard let instVersion = inst.version else { return true }
        return compareVersions(instVersion, catVersion) == .orderedAscending
    }

    // MARK: - Install / uninstall

    /// Installs into `targets`, defaulting to every enabled agent. A failure in
    /// one agent does not stop the others — all errors surface together, so a
    /// bad path on one target can't silently skip the rest.
    func install(_ skill: Skill, into targets: [AgentTarget]? = nil) {
        let destinations = targets ?? enabledTargets
        guard !destinations.isEmpty else {
            lastError = "No agent target is enabled. Turn one on in Settings › Installed Skills."
            return
        }
        var failures: [String] = []
        for target in destinations {
            do {
                try performInstall(skill, into: target)
            } catch {
                failures.append("\(target.kind.displayName): \(error.localizedDescription)")
            }
        }
        refresh()
        if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
    }

    private func performInstall(_ skill: Skill, into target: AgentTarget) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.url, withIntermediateDirectories: true)
        let dest = target.url.appendingPathComponent(skill.path.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: skill.path, to: dest)
        if let catalogID = skill.catalogID {
            let destFile = dest.appendingPathComponent("SKILL.md")
            if let content = try? String(contentsOf: destFile, encoding: .utf8) {
                let marked = Frontmatter.settingOrigin(in: content, catalogID: catalogID)
                if marked != content {
                    try marked.write(to: destFile, atomically: true, encoding: .utf8)
                }
            }
        }
        pruneIgnored(at: dest, ignoring: ignoreMatcher(for: skill))
    }

    /// Removes gitignored junk (e.g. __pycache__) from a freshly copied skill,
    /// using the ignore rules of the catalog the copy came from or goes to.
    private func pruneIgnored(at root: URL, ignoring matcher: GitignoreMatcher) {
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
            if matcher.isIgnored(relativePath: rel) {
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

    /// Copies an installed skill into a catalog (optionally into a subfolder) and
    /// ensures both copies carry a version so update tracking works from now on.
    /// Without an explicit target the primary catalog wins — SM-64 adds the picker.
    func addToCatalog(_ skill: Skill, folder: String = "", to target: Catalog? = nil) {
        guard let target = target ?? primaryCatalog else {
            lastError = GitError.noRepoConfigured.localizedDescription
            return
        }
        do {
            let fm = FileManager.default
            let cleanFolder = folder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
            var destDir = CatalogStore.directory(for: target)
            if !cleanFolder.isEmpty {
                destDir.appendPathComponent(cleanFolder)
            }
            let dest = destDir.appendingPathComponent(skill.path.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                lastError = "“\(skill.path.lastPathComponent)” already exists in “\(target.name)”."
                return
            }
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            try fm.copyItem(at: skill.path, to: dest)
            pruneIgnored(at: dest, ignoring: ignoreMatcher(for: target.id))

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
            try performUninstall(skill)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The Installed list shows one row per skill name even when several agents
    /// hold a copy, so removing that row has to clear every enabled target —
    /// trashing only `skill.path` would leave the other agents' copies behind
    /// and the row would reappear on the next refresh.
    private func performUninstall(_ skill: Skill) throws {
        let fm = FileManager.default
        var removed = false
        var failures: [String] = []
        for target in enabledTargets {
            let copy = target.url.appendingPathComponent(skill.path.lastPathComponent)
            guard fm.fileExists(atPath: copy.path) else { continue }
            do {
                var trashURL: NSURL?
                try fm.trashItem(at: copy, resultingItemURL: &trashURL)
                removed = true
            } catch {
                failures.append("\(target.kind.displayName): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw SkillStoreError.uninstallFailed(failures.joined(separator: "\n"))
        }
        // No enabled target held it — fall back to the scanned path so a copy in
        // a target the user just disabled can still be removed.
        if !removed, fm.fileExists(atPath: skill.path.path) {
            var trashURL: NSURL?
            try fm.trashItem(at: skill.path, resultingItemURL: &trashURL)
        }
    }

    // MARK: - Trials

    /// Whether the configured agent can run a trial at all — gates the "Try
    /// it" control so a CLI without an ad-hoc load mechanism shows a disabled
    /// button instead of failing at runtime after the click.
    var canTryIt: Bool { agentCLI.runner?.supportsTrials ?? false }

    /// Opens a Terminal running the configured agent with `skill` loaded ad
    /// hoc, so it can be exercised before committing to an install. See
    /// `SkillTrial`.
    func tryIt(_ skill: Skill) async {
        do {
            try await SkillTrial.start(skill, model: agentCLI.modelArgument)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Bulk operations

    /// Installs several catalog skills in one go: same per-skill work as
    /// `install(_:)`, but a single `refresh()` at the end instead of one per
    /// item. A failing skill doesn't abort the rest — every error is collected
    /// and reported together.
    func install(_ skills: [Skill], into targets: [AgentTarget]? = nil) {
        let destinations = targets ?? enabledTargets
        guard !destinations.isEmpty else {
            lastError = "No agent target is enabled. Turn one on in Settings › Installed Skills."
            return
        }
        runBatch(skills) { skill in
            for target in destinations { try performInstall(skill, into: target) }
        }
    }

    func uninstall(_ skills: [Skill]) {
        runBatch(skills) { try performUninstall($0) }
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

    // MARK: - Catalogs

    /// Appends a catalog. The name is optional — without one the repo name is
    /// used. Returns nil when the URL is blank or already configured: two
    /// entries on one repo would push each other's commits back and forth.
    @discardableResult
    func addCatalog(name: String = "", repoURL: String) -> Catalog? {
        let url = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        guard !hasCatalog(withRepoURL: url) else {
            lastError = "A catalog for \(url) already exists."
            return nil
        }
        var catalog = Catalog.fromRepoURL(url, taken: Set(catalogs.map(\.slug)))
        let displayName = name.trimmingCharacters(in: .whitespaces)
        if !displayName.isEmpty { catalog.name = displayName }
        guard persist(catalogs + [catalog]) else { return nil }
        return catalog
    }

    func hasCatalog(withRepoURL url: String) -> Bool {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalogs.contains { $0.repoURL.caseInsensitiveCompare(clean) == .orderedSame }
    }

    /// Changes the display name only. The slug — and with it the clone
    /// directory — stays as created, so a rename never orphans a working copy.
    func renameCatalog(_ catalog: Catalog, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != catalog.name,
              let index = catalogs.firstIndex(where: { $0.id == catalog.id }) else { return }
        var updated = catalogs
        updated[index].name = clean
        persist(updated)
    }

    /// Drops the catalog from the list. Its clone goes to the Trash when
    /// `trashingClone` is set — recoverable, like uninstalling a skill — and is
    /// left alone otherwise, so re-adding the same repo reuses the working copy.
    func removeCatalog(_ catalog: Catalog, trashingClone: Bool) {
        let dir = CatalogStore.directory(for: catalog)
        guard persist(catalogs.filter { $0.id != catalog.id }) else { return }
        lastSyncedCommits[catalog.id] = nil
        queuedConflicts.removeAll { $0.catalogID == catalog.id }
        if syncConflict?.catalogID == catalog.id { syncConflict = nil }
        guard trashingClone, FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            var trashURL: NSURL?
            try FileManager.default.trashItem(at: dir, resultingItemURL: &trashURL)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Moves a catalog `offset` slots. The list order is the display order in
    /// the skill list, and the first entry is the default write target.
    func moveCatalog(_ catalog: Catalog, by offset: Int) {
        guard let index = catalogs.firstIndex(where: { $0.id == catalog.id }) else { return }
        let target = index + offset
        guard catalogs.indices.contains(target) else { return }
        var updated = catalogs
        updated.swapAt(index, target)
        persist(updated)
    }

    /// Writes the list first and only then adopts it: a failed save must leave
    /// the UI on the state that is actually on disk.
    @discardableResult
    private func persist(_ updated: [Catalog]) -> Bool {
        do {
            try CatalogStore.save(updated)
            catalogs = updated
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Git sync

    /// Syncs every catalog in order. One catalog failing — or stopping on a
    /// conflict — does not skip the rest: errors are collected and reported
    /// together, conflicts queue up and are resolved one sheet at a time.
    func sync() async {
        await sync(catalogs)
    }

    /// Syncs a single catalog, e.g. from its row in Settings.
    func sync(_ catalog: Catalog) async {
        await sync([catalog])
    }

    private func sync(_ targets: [Catalog]) async {
        guard !targets.isEmpty else {
            lastError = GitError.noRepoConfigured.localizedDescription
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        // A queued conflict from an earlier run is about to be re-detected (or
        // gone) — the fresh result wins over the stale entry.
        queuedConflicts.removeAll { queued in targets.contains { $0.id == queued.catalogID } }

        var failures: [String] = []
        var conflicts: [SyncConflict] = []
        for target in targets {
            do {
                try await syncOne(target)
            } catch GitError.conflict(let files) where !files.isEmpty {
                conflicts.append(SyncConflict(catalog: target, files: files))
            } catch {
                failures.append("\(target.name): \(error.localizedDescription)")
            }
        }
        refresh()
        if !failures.isEmpty {
            lastError = failures.joined(separator: "\n")
        }
        enqueue(conflicts)
    }

    private func syncOne(_ catalog: Catalog) async throws {
        let git = git(for: catalog)
        if !git.isCloned {
            try await git.clone(from: catalog.repoURL)
            git.ensureGitignore()
            return
        }
        git.ensureGitignore()
        // Commit before pulling — rebase refuses on a dirty worktree.
        try await git.commitLocalChanges(message: "Update skills via Skill Manager")
        if await git.remoteHasCommits() {
            try await git.pull()
        }
        try await git.push()
    }

    /// Applies the user's per-file choices to the stopped rebase of the catalog
    /// the open sheet belongs to, and finishes its sync. Another conflicting
    /// commit further along the rebase re-opens the sheet with the new files
    /// instead of erroring out.
    func resolveSyncConflict(_ choices: [String: ConflictResolution]) async {
        guard let conflict = syncConflict else { return }
        isSyncing = true
        defer { isSyncing = false }
        syncConflict = nil
        guard let git = git(forCatalogID: conflict.catalogID) else {
            lastError = "“\(conflict.catalogName)” is no longer configured."
            await presentNextConflict()
            return
        }
        var reopened: [SyncConflict] = []
        do {
            try await git.resolveConflicts(choices)
            try await git.push()
        } catch GitError.conflict(let files) where !files.isEmpty {
            reopened = [SyncConflict(
                catalogID: conflict.catalogID, catalogName: conflict.catalogName, files: files
            )]
        } catch {
            lastError = "\(conflict.catalogName): \(error.localizedDescription)"
        }
        refresh()
        // The same catalog's follow-up conflict goes first — it is the rebase
        // the user is already mid-way through.
        queuedConflicts = reopened + queuedConflicts
        await presentNextConflict()
    }

    /// Drops the rebase of the open sheet's catalog — that catalog goes back to
    /// its pre-sync state. Other catalogs' conflicts still get their turn.
    func cancelSyncConflict() async {
        guard let conflict = syncConflict else { return }
        syncConflict = nil
        if let git = git(forCatalogID: conflict.catalogID) {
            await git.abortRebase()
        }
        refresh()
        await presentNextConflict()
    }

    private func enqueue(_ conflicts: [SyncConflict]) {
        queuedConflicts += conflicts
        if syncConflict == nil, !queuedConflicts.isEmpty {
            syncConflict = queuedConflicts.removeFirst()
        }
    }

    /// Shows the next queued conflict. The pause lets the previous sheet finish
    /// dismissing — SwiftUI drops a new `sheet(item:)` value handed to it mid-
    /// dismissal, and the sheet would never come back.
    private func presentNextConflict() async {
        guard !queuedConflicts.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(400))
        syncConflict = queuedConflicts.removeFirst()
    }

    /// Clones a catalog that has no working copy yet.
    func clone(_ catalog: Catalog) async {
        isSyncing = true
        defer { isSyncing = false }
        let git = git(for: catalog)
        do {
            try await git.clone(from: catalog.repoURL)
            git.ensureGitignore()
            refresh()
        } catch {
            lastError = "\(catalog.name): \(error.localizedDescription)"
        }
    }
}

/// The files a Sync stopped on in one catalog, as a presentable unit for
/// `sheet(item:)`. The name is carried along so the sheet can still say which
/// catalog it is about after the catalog was removed mid-sync.
struct SyncConflict: Identifiable {
    let id = UUID()
    let catalogID: UUID?
    let catalogName: String
    let files: [String]

    init(catalogID: UUID?, catalogName: String, files: [String]) {
        self.catalogID = catalogID
        self.catalogName = catalogName
        self.files = files
    }

    init(catalog: Catalog, files: [String]) {
        self.init(catalogID: catalog.id, catalogName: catalog.name, files: files)
    }
}

enum SkillStoreError: LocalizedError {
    case uninstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .uninstallFailed(let detail): "Could not uninstall:\n\(detail)"
        }
    }
}
