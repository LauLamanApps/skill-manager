import Foundation
import SwiftUI

/// Runs Claude Code headless (`claude -p`) to generate or edit skills in the catalog.
///
/// One runner owns one conversation: the first call opens a Claude Code
/// session, every later call resumes it by session id, so a follow-up like
/// "no, use snake_case instead" lands in a context that still knows what was
/// just written.
@MainActor
final class ClaudeRunner: ObservableObject {
    /// One user instruction plus everything Claude Code emitted in response.
    struct ChatTurn: Identifiable {
        let id = UUID()
        let prompt: String
        var output: String = ""
    }

    @Published private(set) var turns: [ChatTurn] = []
    @Published var isRunning = false
    @Published var finishedSuccessfully: Bool?
    /// Whether the turn that just finished ran read-only (Ask mode). Callers
    /// use this to skip `store.refresh()` — a read-only run cannot have
    /// touched any file.
    @Published private(set) var lastRunWasReadOnly = false

    /// Files Claude Code touched since the review baseline, awaiting Keep or
    /// Revert. Accumulates across turns: the baseline is only reset once the
    /// user accepts or reverts, so a follow-up turn shows the net effect of the
    /// whole conversation.
    @Published private(set) var changes: [FileChange] = []
    /// Set when a revert could not restore a file; cleared on the next attempt.
    @Published var revertError: String?

    /// Composer state of the conversation: the half-typed follow-up and the
    /// Ask/Edit toggle. Kept here rather than in the view so it survives the
    /// view being torn down and rebuilt, like the transcript does.
    @Published var draft: String = ""
    @Published var askOnly = false

    /// Session the CLI reported on the first turn; later turns resume it.
    private(set) var sessionID: String?

    private var activeHandle: ShellHandle?
    private var cancelRequested = false

    /// State of the working directory before the first unreviewed turn.
    private var baseline: DirectorySnapshot?
    private var ignoreMatcher = GitignoreMatcher(lines: GitignoreMatcher.defaultPatterns)

    /// Transcript of the turn currently in flight (or the last finished one).
    var output: String { turns.last?.output ?? "" }

    var hasTranscript: Bool { !turns.isEmpty }

    /// Whether this runner still holds something a returning view should see.
    /// A runner that was only ever created — the user opened a skill and typed
    /// nothing — has nothing to restore and can be dropped.
    var hasRestorableState: Bool {
        isRunning || hasTranscript || !changes.isEmpty
            || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func skillAuthoringPrompt(instruction: String) -> String {
        """
        You are editing a catalog of Claude Code skills. Each skill is a directory \
        containing a SKILL.md file with YAML frontmatter: name (kebab-case, matching \
        the directory name), description (one line, states when to use the skill), \
        version (semver, e.g. 1.0.0), and optional tags (inline YAML list of short \
        lowercase keywords, e.g. tags: [php, testing]). Skills may live in \
        subdirectories of the catalog, which act as folders for organization.

        Rules:
        - When creating a skill, create <skill-name>/SKILL.md with version 1.0.0 \
        and 2-4 tags matching the skill's topic; reuse tags already present in the \
        catalog when they fit.
        - When editing an existing skill, apply the change and bump the version: \
        patch for wording fixes, minor for new content, major for breaking rewrites.
        - Keep SKILL.md focused and actionable; move long reference material to \
        separate files in the skill directory and link them from SKILL.md.
        - Do not touch unrelated skills.

        Task:
        \(instruction)
        """
    }

    /// `--verbose` is what makes `--output-format stream-json` legal together
    /// with `-p`; without it the CLI refuses to start. `plan` mode makes the
    /// CLI refuse edits outright, so Ask mode can't accidentally change a file.
    private static func command(resuming sessionID: String?, readOnly: Bool, model: String? = nil) -> String {
        var parts = ["claude", "-p", "--permission-mode", readOnly ? "plan" : "acceptEdits"]
        if let sessionID { parts += ["--resume", sessionID] }
        if let model, !model.isEmpty { parts += ["--model", model] }
        parts += ["--output-format", "stream-json", "--verbose"]
        return parts.joined(separator: " ")
    }

    /// Sends one instruction and appends its answer as a new turn.
    ///
    /// `context` frames what is being worked on (which skill, which folder).
    /// It is only sent on the first turn — a resumed session already has it,
    /// and repeating it every time just fights the conversation history.
    ///
    /// `ignoring` keeps the diff snapshot of `cwd` to the files the app itself
    /// considers part of a skill.
    ///
    /// `readOnly` runs the CLI in `--permission-mode plan`, which refuses any
    /// edit — for questions about a skill that must not risk changing it.
    func run(
        instruction: String,
        cwd: URL,
        context: String? = nil,
        ignoring: GitignoreMatcher? = nil,
        readOnly: Bool = false,
        model: String? = nil
    ) {
        guard !isRunning else { return }
        let resumedSession = sessionID
        finishedSuccessfully = nil
        isRunning = true
        cancelRequested = false
        lastRunWasReadOnly = readOnly
        if let ignoring { ignoreMatcher = ignoring }
        turns.append(ChatTurn(prompt: instruction))
        let handle = ShellHandle()
        activeHandle = handle

        let prompt: String
        if resumedSession == nil {
            let framed = [context, instruction]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            prompt = Self.skillAuthoringPrompt(instruction: framed)
        } else {
            prompt = instruction
        }
        let command = Self.command(resuming: resumedSession, readOnly: readOnly, model: model)

        Task {
            // Taken before the CLI starts, so everything it writes shows up as
            // a diff afterwards. A conversation keeps its first baseline until
            // the user reviews the result. Skipped for a read-only run — plan
            // mode can't write, so there is nothing to diff.
            if !readOnly, baseline == nil || baseline?.root != cwd.standardizedFileURL {
                let matcher = ignoreMatcher
                baseline = await Task.detached {
                    DirectorySnapshot.capture(root: cwd, ignoring: matcher)
                }.value
            }

            // The stream keeps the lines in order; separate per-line tasks
            // would not, and the transcript would scramble.
            let (lines, continuation) = AsyncStream<String>.makeStream(of: String.self)
            let consumer = Task { @MainActor [weak self] in
                for await line in lines { self?.append(line: line) }
            }

            var producedOutput = false
            do {
                let result = try await Shell.streamInLoginShell(
                    command,
                    cwd: cwd,
                    stdin: prompt,
                    handle: handle,
                    onLine: { continuation.yield($0) }
                )
                continuation.finish()
                await consumer.value
                producedOutput = !output.isEmpty

                if cancelRequested {
                    appendToCurrentTurn("Cancelled.")
                } else if !producedOutput {
                    // Nothing decodable arrived — show whatever the CLI said.
                    appendToCurrentTurn(result.combinedOutput)
                } else if !result.succeeded, !result.stderr.isEmpty {
                    appendToCurrentTurn(result.stderr)
                }
                finishedSuccessfully = cancelRequested ? false : result.succeeded
            } catch {
                continuation.finish()
                await consumer.value
                appendToCurrentTurn(error.localizedDescription)
                finishedSuccessfully = false
            }

            // A resume that failed without producing a single event usually
            // means the session is gone (expired, or its transcript removed).
            // Drop it so the next turn opens a fresh one instead of failing
            // the same way forever.
            if resumedSession != nil, !cancelRequested, !producedOutput,
               finishedSuccessfully != true {
                sessionID = nil
            }
            activeHandle = nil
            // Also after a failed or cancelled run — a partial edit is exactly
            // what the user wants to see and undo. Not for a read-only run:
            // there is no baseline, so nothing to diff.
            if !readOnly { await refreshChanges() }
            isRunning = false
        }
    }

    /// Accepts the pending changes: the files stay as they are, and the next
    /// turn starts a fresh review from this state.
    func acceptChanges() {
        guard !isRunning else { return }
        changes = []
        baseline = nil
        revertError = nil
    }

    /// Forgets the conversation so the next turn opens a fresh Claude Code
    /// session instead of resuming this one. Pending changes are dropped from
    /// review as-is — like `acceptChanges()`, the files on disk stay put.
    func reset() {
        guard !isRunning else { return }
        turns = []
        sessionID = nil
        changes = []
        baseline = nil
        revertError = nil
        finishedSuccessfully = nil
        draft = ""
    }

    /// Restores every pending change.
    func revertAll() async {
        await revert(changes)
    }

    /// Restores a single file to its pre-run state.
    func revert(_ change: FileChange) async {
        await revert([change])
    }

    private func revert(_ list: [FileChange]) async {
        guard !isRunning, !list.isEmpty, let root = baseline?.root else { return }
        revertError = nil
        let failures = await Task.detached { () -> [String] in
            var failures: [String] = []
            // Deepest first, so a directory is empty by the time its own
            // removal is considered.
            for change in list.sorted(by: { $0.path.count > $1.path.count }) {
                do {
                    try change.revert(in: root)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            return failures
        }.value
        if !failures.isEmpty { revertError = failures.joined(separator: "\n") }
        // Recomputed rather than filtered: whatever is still different from the
        // baseline is still pending, however the reverts went.
        await refreshChanges()
        if changes.isEmpty { baseline = nil }
    }

    /// Re-diffs the working directory against the review baseline.
    private func refreshChanges() async {
        guard let baseline else { return }
        let matcher = ignoreMatcher
        changes = await Task.detached {
            let after = DirectorySnapshot.capture(root: baseline.root, ignoring: matcher)
            return DirectorySnapshot.changes(from: baseline, to: after)
        }.value
    }

    /// Terminates the running Claude Code process, if any. The in-flight
    /// `run` still resolves normally afterwards and marks itself cancelled.
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        activeHandle?.terminate()
    }

    /// Decodes one stream line into the current turn, and picks up the session
    /// id the first time the CLI reports one.
    private func append(line: String) {
        let decoded = ClaudeStreamEvent.parse(line: line)
        if sessionID == nil, let id = decoded.sessionID, UUID(uuidString: id) != nil {
            sessionID = id
        }
        for fragment in decoded.events.compactMap(\.displayText) {
            appendToCurrentTurn(fragment)
        }
    }

    private func appendToCurrentTurn(_ text: String) {
        guard !text.isEmpty, let index = turns.indices.last else { return }
        if !turns[index].output.isEmpty { turns[index].output += "\n" }
        turns[index].output += text
    }

    /// True if a `claude` binary is reachable from a login shell.
    static func checkAvailability() async -> String? {
        let result = try? await Shell.runInLoginShell("command -v claude && claude --version")
        guard let result, result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
