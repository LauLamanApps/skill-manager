import Foundation

/// Byte-level picture of a directory tree, taken right before Claude Code runs
/// so its edits can be shown as a diff and undone afterwards.
///
/// Git is deliberately not used for this. The catalog worktree routinely holds
/// uncommitted work of the user's own (an AI-generated skill waits for Sync to
/// commit it), and `git checkout -- <path>` reverts to HEAD — which would throw
/// that work away together with Claude's edits. A snapshot restores exactly the
/// state that existed when the run started, nothing more. It also covers
/// installed skills under `~/.claude/skills`, which are not a git repo at all.
struct DirectorySnapshot: Sendable {
    /// One regular file at snapshot time.
    struct Entry: Sendable, Equatable {
        /// File contents, or nil when the file was larger than `maxFileSize` —
        /// those are still tracked for change detection, but cannot be restored.
        let data: Data?
        let size: Int
        let modified: Date
    }

    /// Above this, contents are not kept in memory. Skills are text; anything
    /// bigger is an attachment that a diff view could not show anyway.
    static let maxFileSize = 2 * 1024 * 1024

    let root: URL
    let entries: [String: Entry]

    /// Reads every non-ignored regular file below `root`. Hidden entries (`.git`,
    /// `.DS_Store`) are skipped, as they are everywhere else in the app.
    ///
    /// Blocking file IO — call it off the main actor.
    static func capture(root: URL, ignoring: GitignoreMatcher) -> DirectorySnapshot {
        let base = root.standardizedFileURL
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]
        var entries: [String: Entry] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            return DirectorySnapshot(root: base, entries: [:])
        }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let relative = relativePath(of: url, under: base)
            guard !relative.isEmpty, !ignoring.isIgnored(relativePath: relative) else { continue }
            let size = values.fileSize ?? 0
            entries[relative] = Entry(
                data: size <= maxFileSize ? try? Data(contentsOf: url) : nil,
                size: size,
                modified: values.contentModificationDate ?? .distantPast
            )
        }
        return DirectorySnapshot(root: base, entries: entries)
    }

    /// Everything that differs between two snapshots of the same tree, sorted by
    /// path. Blocking (it diffs file contents) — call it off the main actor.
    static func changes(
        from before: DirectorySnapshot, to after: DirectorySnapshot
    ) -> [FileChange] {
        var changes: [FileChange] = []
        for path in Set(before.entries.keys).union(after.entries.keys).sorted() {
            switch (before.entries[path], after.entries[path]) {
            case let (old?, new?):
                guard differ(old, new) else { continue }
                changes.append(FileChange(path: path, kind: .modified, before: old, after: new))
            case let (nil, new?):
                changes.append(FileChange(path: path, kind: .added, before: nil, after: new))
            case let (old?, nil):
                changes.append(FileChange(path: path, kind: .deleted, before: old, after: nil))
            case (nil, nil):
                continue
            }
        }
        return changes
    }

    /// Contents decide when both sides were small enough to read; for the rest,
    /// size and modification date are the best signal available.
    private static func differ(_ old: Entry, _ new: Entry) -> Bool {
        if let oldData = old.data, let newData = new.data { return oldData != newData }
        return old.size != new.size || old.modified != new.modified
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// One file Claude Code touched, with the line diff already computed.
struct FileChange: Identifiable, Sendable {
    enum Kind: Sendable {
        case added
        case modified
        case deleted
    }

    let path: String
    let kind: Kind
    let before: DirectorySnapshot.Entry?
    let after: DirectorySnapshot.Entry?
    /// Empty when `isTextDiffable` is false.
    let diff: [DiffLine]
    let insertions: Int
    let deletions: Int
    /// False for binary files and for files too large to have been snapshotted —
    /// both are reported as changed, but there is nothing to render line by line.
    let isTextDiffable: Bool

    var id: String { path }

    /// An added file can always be deleted again; restoring anything else needs
    /// the pre-run contents, which oversized files do not carry.
    var canRevert: Bool {
        kind == .added || before?.data != nil
    }

    init(path: String, kind: Kind, before: DirectorySnapshot.Entry?, after: DirectorySnapshot.Entry?) {
        self.path = path
        self.kind = kind
        self.before = before
        self.after = after

        // A side that does not exist yet (added) or no longer exists (deleted)
        // is diffable as the empty document; every other side has to decode.
        let oldText = Self.text(of: before)
        let newText = Self.text(of: after)
        isTextDiffable = (kind == .added || oldText != nil)
            && (kind == .deleted || newText != nil)
        diff = isTextDiffable
            ? LineDiff.unified(old: oldText ?? "", new: newText ?? "")
            : []
        insertions = diff.reduce(into: 0) { $0 += $1.kind == .insertion ? 1 : 0 }
        deletions = diff.reduce(into: 0) { $0 += $1.kind == .deletion ? 1 : 0 }
    }

    /// UTF-8 text of an entry, or nil when it is binary or was not snapshotted.
    private static func text(of entry: DirectorySnapshot.Entry?) -> String? {
        guard let data = entry?.data else { return nil }
        guard !data.prefix(4096).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Puts this file back the way it was before the run.
    ///
    /// Blocking file IO — call it off the main actor.
    func revert(in root: URL) throws {
        let url = root.appendingPathComponent(path)
        let fm = FileManager.default
        switch kind {
        case .added:
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            Self.pruneEmptyDirectories(from: url.deletingLastPathComponent(), stoppingAt: root)
        case .modified, .deleted:
            guard let data = before?.data else { throw FileRevertError.notRevertable(path) }
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            if let modified = before?.modified {
                try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
        }
    }

    /// Removing a generated `some-skill/SKILL.md` leaves `some-skill/` behind;
    /// walk up and drop directories that the revert just emptied.
    private static func pruneEmptyDirectories(from directory: URL, stoppingAt root: URL) {
        let fm = FileManager.default
        var current = directory.standardizedFileURL
        let stop = root.standardizedFileURL.path
        while current.path != stop, current.path.hasPrefix(stop),
              let contents = try? fm.contentsOfDirectory(atPath: current.path),
              contents.isEmpty {
            try? fm.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }
}

enum FileRevertError: LocalizedError {
    case notRevertable(String)

    var errorDescription: String? {
        switch self {
        case .notRevertable(let path):
            return "“\(path)” was too large to snapshot before the run and can't be reverted."
        }
    }
}
