import Foundation

enum GitError: LocalizedError {
    case noRepoConfigured
    case notCloned

    var errorDescription: String? {
        switch self {
        case .noRepoConfigured: return "No catalog repository URL configured. Set one in Settings."
        case .notCloned: return "Catalog is not cloned yet. Clone it from Settings or hit Sync."
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

    func pull() async throws {
        guard isCloned else { throw GitError.notCloned }
        try await Shell.runChecked(Self.git, ["-C", catalogDir.path, "pull", "--rebase"])
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
