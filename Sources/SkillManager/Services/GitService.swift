import Foundation

enum GitError: LocalizedError {
    case noRepoConfigured
    case notCloned
    /// The rebase started by `pull()` stopped on conflicting files. The repo is
    /// left mid-rebase on purpose so the user can resolve and continue.
    case conflict(files: [String])

    var errorDescription: String? {
        switch self {
        case .noRepoConfigured: return "No catalogs configured. Add one in Settings."
        case .notCloned: return "Catalog is not cloned yet. Clone it from Settings or hit Sync."
        case .conflict(let files):
            return "Sync stopped on \(files.count) conflicting file(s): "
                + files.joined(separator: ", ")
        }
    }
}

/// Which side of a conflicting file wins. During a `pull --rebase` the local
/// commits are the ones being replayed, so "local" is `REBASE_HEAD` and
/// "remote" is `HEAD` — not the other way round.
enum ConflictResolution: String, CaseIterable, Identifiable {
    case keepLocal
    case keepRemote

    var id: String { rawValue }
    var label: String {
        switch self {
        case .keepLocal: return "Keep Local"
        case .keepRemote: return "Keep Remote"
        }
    }

    /// Revision to take the file contents from while a rebase is stopped.
    var revision: String {
        switch self {
        case .keepLocal: return "REBASE_HEAD"
        case .keepRemote: return "HEAD"
        }
    }
}

struct GitService {
    static let git = "/usr/bin/git"

    let catalogDir: URL

    var isCloned: Bool {
        FileManager.default.fileExists(
            atPath: catalogDir.appendingPathComponent(".git").path
        )
    }

    func clone(from remoteURL: String) async throws {
        guard !remoteURL.isEmpty else { throw GitError.noRepoConfigured }
        try FileManager.default.createDirectory(
            at: catalogDir.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await Shell.runChecked(Self.git, ["clone", remoteURL, catalogDir.path])
    }

    /// Seeds the catalog's .gitignore with the default junk patterns. Only when
    /// the file is missing — an existing one is the user's to manage.
    func ensureGitignore() {
        let url = catalogDir.appendingPathComponent(".gitignore")
        guard isCloned, !FileManager.default.fileExists(atPath: url.path) else { return }
        try? GitignoreMatcher.defaultFileContents
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Rebases onto the remote. A rebase that stops on conflicts throws
    /// `GitError.conflict` (repo left mid-rebase, resolvable via
    /// `resolveConflicts` or `abortRebase`); any other failure throws the
    /// underlying `ShellError`.
    func pull() async throws {
        guard isCloned else { throw GitError.notCloned }
        let result = try await Shell.run(
            Self.git, ["-C", catalogDir.path, "pull", "--rebase"]
        )
        guard !result.succeeded else { return }
        let files = await conflictedFiles()
        guard files.isEmpty else { throw GitError.conflict(files: files) }
        throw ShellError.failed(command: "git pull --rebase", result: result)
    }

    /// Paths git reports as unmerged (stage > 0) right now.
    func conflictedFiles() async -> [String] {
        guard let result = try? await Shell.run(
            Self.git,
            ["-C", catalogDir.path, "diff", "--name-only", "--diff-filter=U", "-z"]
        ), result.succeeded else { return [] }
        return result.stdout.split(separator: "\0").map(String.init)
    }

    var isRebaseInProgress: Bool {
        let git = catalogDir.appendingPathComponent(".git")
        return ["rebase-merge", "rebase-apply"].contains {
            FileManager.default.fileExists(atPath: git.appendingPathComponent($0).path)
        }
    }

    /// Resolves the stopped rebase by taking each file wholesale from one side,
    /// then continues it. A later commit in the same rebase can conflict again —
    /// that throws `GitError.conflict` with the new file list, so the caller can
    /// ask once more. Files without a choice default to keeping the local side.
    func resolveConflicts(_ choices: [String: ConflictResolution]) async throws {
        guard isCloned else { throw GitError.notCloned }
        for file in await conflictedFiles() {
            let side = choices[file] ?? .keepLocal
            let checkout = try await Shell.run(
                Self.git, ["-C", catalogDir.path, "checkout", side.revision, "--", file]
            )
            if checkout.succeeded {
                try await Shell.runChecked(Self.git, ["-C", catalogDir.path, "add", "--", file])
            } else {
                // The chosen side deleted the file — record the deletion instead.
                try await Shell.runChecked(
                    Self.git, ["-C", catalogDir.path, "rm", "--force", "--", file]
                )
            }
        }
        // `-c core.editor=true` keeps the commit message git already has instead
        // of blocking on an editor that this app has no terminal for.
        let result = try await Shell.run(
            Self.git,
            ["-C", catalogDir.path, "-c", "core.editor=true", "rebase", "--continue"]
        )
        guard !result.succeeded else { return }
        let remaining = await conflictedFiles()
        guard remaining.isEmpty else { throw GitError.conflict(files: remaining) }
        throw ShellError.failed(command: "git rebase --continue", result: result)
    }

    /// Drops the in-flight rebase and puts the worktree back where it was.
    func abortRebase() async {
        guard isRebaseInProgress else { return }
        _ = try? await Shell.run(Self.git, ["-C", catalogDir.path, "rebase", "--abort"])
    }

    /// False for a freshly created remote with no commits — `pull` would fail
    /// there ("no such ref was fetched") and must be skipped.
    func remoteHasCommits() async -> Bool {
        guard let result = try? await Shell.run(
            Self.git, ["-C", catalogDir.path, "ls-remote", "--heads", "origin"]
        ) else { return false }
        return result.succeeded
            && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stages everything and commits if there are changes. Must run before
    /// `pull()` — a rebase refuses to start on a dirty worktree.
    func commitLocalChanges(message: String) async throws {
        guard isCloned else { throw GitError.notCloned }
        try await Shell.runChecked(Self.git, ["-C", catalogDir.path, "add", "-A"])
        let status = try await Shell.runChecked(
            Self.git, ["-C", catalogDir.path, "status", "--porcelain"]
        )
        if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await Shell.runChecked(
                Self.git, ["-C", catalogDir.path, "commit", "-m", message]
            )
        }
    }

    /// Stages the given paths and commits them if they hold changes.
    /// Pushing stays with Sync.
    func commit(paths: [String], message: String) async throws {
        guard isCloned else { throw GitError.notCloned }
        try await Shell.runChecked(
            Self.git, ["-C", catalogDir.path, "add", "--"] + paths
        )
        let status = try await Shell.runChecked(
            Self.git, ["-C", catalogDir.path, "status", "--porcelain", "--"] + paths
        )
        if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await Shell.runChecked(
                Self.git, ["-C", catalogDir.path, "commit", "-m", message, "--"] + paths
            )
        }
    }

    func push() async throws {
        guard isCloned else { throw GitError.notCloned }
        // A clone of an empty repo has no upstream yet; first push must set it.
        let upstream = try? await Shell.run(
            Self.git,
            ["-C", catalogDir.path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
        )
        if upstream?.succeeded == true {
            try await Shell.runChecked(Self.git, ["-C", catalogDir.path, "push"])
        } else {
            try await Shell.runChecked(
                Self.git, ["-C", catalogDir.path, "push", "-u", "origin", "HEAD"]
            )
        }
    }

    func currentBranch() async throws -> String {
        try await Shell.runChecked(
            Self.git, ["-C", catalogDir.path, "rev-parse", "--abbrev-ref", "HEAD"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commits the given paths on a new branch, pushes it, and returns the URL
    /// to open: the created PR (via `gh` when available) or the GitHub compare
    /// page as fallback. The original branch is checked out again afterwards.
    func createPullRequest(
        paths: [String], branch: String, title: String, body: String
    ) async throws -> URL? {
        guard isCloned else { throw GitError.notCloned }
        let original = try await currentBranch()
        try await Shell.runChecked(Self.git, ["-C", catalogDir.path, "checkout", "-b", branch])
        do {
            try await commit(paths: paths, message: title)
            try await Shell.runChecked(
                Self.git, ["-C", catalogDir.path, "push", "-u", "origin", branch]
            )
        } catch {
            _ = try? await Shell.run(Self.git, ["-C", catalogDir.path, "checkout", original])
            _ = try? await Shell.run(Self.git, ["-C", catalogDir.path, "branch", "-D", branch])
            throw error
        }

        var prURL: URL?
        if let gh = try? await Shell.runInLoginShell("command -v gh", cwd: catalogDir),
           gh.succeeded {
            let create = try? await Shell.runInLoginShell(
                "gh pr create --head \(Self.shellQuote(branch)) "
                    + "--title \(Self.shellQuote(title)) --body \(Self.shellQuote(body))",
                cwd: catalogDir
            )
            if let create, create.succeeded,
               let line = create.stdout
                   .components(separatedBy: "\n")
                   .map({ $0.trimmingCharacters(in: .whitespaces) })
                   .last(where: { $0.hasPrefix("http") }) {
                prURL = URL(string: line)
            }
        }
        if prURL == nil,
           let remote = try? await Shell.runChecked(
               Self.git, ["-C", catalogDir.path, "remote", "get-url", "origin"]
           ) {
            prURL = Self.compareURL(
                remote: remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                branch: branch
            )
        }
        try await Shell.runChecked(Self.git, ["-C", catalogDir.path, "checkout", original])
        return prURL
    }

    /// GitHub "open a PR" compare page for a pushed branch; understands ssh
    /// (git@host:owner/repo.git) and https remotes.
    static func compareURL(remote: String, branch: String) -> URL? {
        var repo = remote
        if repo.hasPrefix("git@") {
            repo = "https://" + repo.dropFirst("git@".count)
                .replacingOccurrences(of: ":", with: "/")
        }
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard let encoded = branch.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) else { return nil }
        return URL(string: "\(repo)/compare/\(encoded)?expand=1")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func lastSyncedCommit() async -> String? {
        guard isCloned else { return nil }
        let result = try? await Shell.run(
            Self.git, ["-C", catalogDir.path, "log", "-1", "--format=%h %s (%cr)"]
        )
        guard let result, result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
