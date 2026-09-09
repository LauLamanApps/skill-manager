import Foundation

/// `AgentRunner` for OpenAI's Codex CLI.
///
/// Its non-interactive entry point is `codex exec`, which streams newline-
/// delimited JSON under `--json`. Two things make it shaped differently from
/// Claude Code: resuming is a *subcommand* (`codex exec resume <id>`) rather
/// than a flag, and edit permission is a sandbox level rather than a permission
/// mode — `read-only` is the default, `workspace-write` is what allows writes
/// inside the working directory.
///
/// The prompt is passed as `-`, the argument form that makes `exec` read it
/// from stdin, which is how `ClaudeRunner` feeds every turn.
///
/// The event schema has drifted across releases: the current builds wrap items
/// in `thread.started` / `turn.*` / `item.*` envelopes, older ones emit a flat
/// `{"id":…,"msg":{"type":…}}` event, and some in between name a message item
/// `assistant_message` instead of `agent_message`. `parse` accepts all three
/// rather than betting on one, since the installed version is the user's choice
/// and not ours.
struct CodexRunner: AgentRunner {
    let displayName = "Codex"
    let binaryName = "codex"

    /// How the CLI is invoked: a bare name resolved from the login shell PATH,
    /// or the absolute path the user configured.
    var launchPath: String = "codex"

    let supportsResume = true
    /// There is no `--plugin-dir` equivalent, and none is needed: Codex finds
    /// skills by scanning `.agents/skills/` from the working directory upward,
    /// so a trial is a scratch cwd with the skill symlinked into it.
    let trialLayout: TrialLayout? = .workspaceSkills
    let supportsToolCards = true

    /// `exec` is the non-interactive mode; it never prompts for approval. The
    /// sandbox is what decides whether a turn may write, so Ask mode maps onto
    /// `read-only` — the CLI's own default, passed explicitly so a changed
    /// default in some future release cannot silently grant write access.
    ///
    /// `resume` takes the session id positionally, before the options.
    ///
    /// No `--skip-git-repo-check`: every run happens inside a catalog, and a
    /// catalog is a git clone, so the check Codex does on its own passes.
    func command(resuming sessionID: String?, readOnly: Bool, model: String?) -> String {
        var parts = [quoted(launchPath), "exec"]
        if let sessionID { parts += ["resume", quoted(sessionID)] }
        parts += ["--json", "--sandbox", readOnly ? "read-only" : "workspace-write"]
        if let model, !model.isEmpty { parts += ["--model", quoted(model)] }
        // Prompt arrives on stdin.
        parts.append("-")
        return parts.joined(separator: " ")
    }

    /// No `--json` here: the caller wants the answer as plain text on stdout,
    /// and reads it line by line. No model either — Codex's model names are the
    /// user's to know, so a classification prompt takes whatever the CLI
    /// defaults to.
    func oneShotCommand() -> String {
        "\(quoted(launchPath)) exec --sandbox read-only -"
    }

    /// Nothing to point at: the trial's workspace *is* the skill's scope, so
    /// the interactive CLI started there discovers `.agents/skills/<skill>` on
    /// its own — symlinked folders included, which is what keeps the trial live
    /// against edits in the app.
    ///
    /// The trial workspace is a fresh directory, so the TUI opens with its
    /// directory-trust step ("trust and continue" or quit). That is unavoidable
    /// and correct for a scratch folder: the alternative would be writing the
    /// throwaway path into the user's own Codex config. Note that the harder
    /// "not inside a trusted directory" *error* belongs to `codex exec`, and so
    /// does its `--skip-git-repo-check` escape hatch — neither applies here.
    ///
    /// `--model` is a global flag on the base command, not an `exec`-only one.
    func trialCommand(_ trial: PreparedTrial, model: String?) -> String? {
        var command = quoted(launchPath)
        if let model, !model.isEmpty {
            command += " --model \(quoted(model))"
        }
        return command
    }

    /// True if the configured binary is reachable from a login shell.
    func checkAvailability() async -> String? {
        let binary = quoted(launchPath)
        let result = try? await Shell.runInLoginShell("command -v \(binary) && \(binary) --version")
        guard let result, result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parse(line: String) -> AgentStreamLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return AgentStreamLine(events: [.raw(trimmed)], sessionID: nil)
        }

        let sessionID = Self.sessionID(in: object)
        let events: [AgentStreamEvent]
        switch object["type"] as? String {
        case "thread.started", "turn.started", "item.updated":
            events = [.ignored]
        case "item.started":
            events = Self.startedEvent(forItem: object["item"] as? [String: Any]).map { [$0] } ?? []
        case "item.completed":
            events = Self.completedEvent(forItem: object["item"] as? [String: Any]).map { [$0] } ?? []
        case "turn.completed":
            events = [.result(text: nil, isError: false)]
        case "turn.failed":
            events = [.result(text: Self.errorMessage(in: object), isError: true)]
        case "error":
            events = [.result(text: Self.errorMessage(in: object), isError: true)]
        default:
            events = Self.legacyEvents(in: object)
        }
        return AgentStreamLine(events: events, sessionID: sessionID)
    }

    // MARK: - Items

    /// What an item is doing, once its `type` spelling is normalized across
    /// releases. Anything unrecognized keeps its own name, so a tool added in a
    /// later Codex still shows up as a tool card instead of vanishing.
    private static func itemKind(_ item: [String: Any]) -> String? {
        guard let raw = (item["type"] ?? item["item_type"]) as? String else { return nil }
        switch raw {
        case "assistant_message", "agent_message", "message": return "agent_message"
        case "command_execution", "exec_command", "local_shell_call": return "command_execution"
        case "file_change", "patch_apply": return "file_change"
        case "mcp_tool_call": return "mcp_tool_call"
        case "web_search", "web_search_call": return "web_search"
        default: return raw
        }
    }

    /// Tool activity is announced when an item starts. It is deliberately not
    /// repeated on completion — the alternative is two transcript lines per
    /// command — so a build that only ever emits `item.completed` shows tool
    /// failures but no tool cards.
    private static func startedEvent(forItem item: [String: Any]?) -> AgentStreamEvent? {
        guard let item, let kind = itemKind(item) else { return nil }
        switch kind {
        case "command_execution":
            return .toolUse(name: "shell", detail: shortened(commandText(item)))
        case "file_change":
            return .toolUse(name: "edit", detail: shortened(changedPaths(item)))
        case "mcp_tool_call":
            return .toolUse(name: mcpToolName(item), detail: nil)
        case "web_search":
            return .toolUse(name: "web_search", detail: shortened(item["query"] as? String))
        default:
            // reasoning, todo lists, and the message item itself: nothing to
            // show until they complete.
            return nil
        }
    }

    private static func completedEvent(forItem item: [String: Any]?) -> AgentStreamEvent? {
        guard let item, let kind = itemKind(item) else { return nil }
        switch kind {
        case "agent_message":
            guard let text = messageText(item), !text.isEmpty else { return nil }
            return .text(text)
        case "command_execution", "file_change", "mcp_tool_call":
            return failed(item) ? .toolFailed : nil
        default:
            return nil
        }
    }

    /// Whether a completed item reports a failure. Codex marks this with a
    /// `status` string on newer builds and an exit code on the command items.
    private static func failed(_ item: [String: Any]) -> Bool {
        if let status = item["status"] as? String {
            return ["failed", "error", "aborted", "cancelled", "canceled"].contains(status)
        }
        if let exitCode = item["exit_code"] as? Int { return exitCode != 0 }
        if let success = item["success"] as? Bool { return !success }
        return false
    }

    private static func messageText(_ item: [String: Any]) -> String? {
        for key in ["text", "message", "content"] {
            if let value = item[key] as? String { return value }
        }
        return nil
    }

    /// The command being run, whether it arrives as a string or as argv.
    private static func commandText(_ item: [String: Any]) -> String? {
        if let command = item["command"] as? String { return command }
        if let argv = item["command"] as? [String] { return argv.joined(separator: " ") }
        return nil
    }

    /// Paths a file-change item touches. `changes` is a path-keyed object on
    /// some builds and a list of entries on others.
    private static func changedPaths(_ item: [String: Any]) -> String? {
        var paths: [String] = []
        if let map = item["changes"] as? [String: Any] {
            paths = map.keys.sorted()
        } else if let list = item["changes"] as? [[String: Any]] {
            paths = list.compactMap { $0["path"] as? String }
        } else if let path = item["path"] as? String {
            paths = [path]
        }
        guard !paths.isEmpty else { return nil }
        return paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
    }

    private static func mcpToolName(_ item: [String: Any]) -> String {
        let tool = item["tool"] as? String ?? "tool"
        guard let server = item["server"] as? String, !server.isEmpty else { return tool }
        return "\(server).\(tool)"
    }

    // MARK: - Legacy event envelope

    /// Pre-`thread.*` builds emit `{"id": "0", "msg": {"type": …}}`, with the
    /// same information under different names.
    private static func legacyEvents(in object: [String: Any]) -> [AgentStreamEvent] {
        guard let msg = object["msg"] as? [String: Any] else { return [.ignored] }
        switch msg["type"] as? String {
        case "agent_message":
            guard let text = messageText(msg), !text.isEmpty else { return [.ignored] }
            return [.text(text)]
        case "exec_command_begin":
            return [.toolUse(name: "shell", detail: shortened(commandText(msg)))]
        case "exec_command_end":
            return failed(msg) ? [.toolFailed] : [.ignored]
        case "patch_apply_begin":
            return [.toolUse(name: "edit", detail: shortened(changedPaths(msg)))]
        case "patch_apply_end":
            return failed(msg) ? [.toolFailed] : [.ignored]
        case "mcp_tool_call_begin":
            return [.toolUse(name: mcpToolName(msg), detail: nil)]
        case "mcp_tool_call_end":
            return failed(msg) ? [.toolFailed] : [.ignored]
        case "task_complete":
            return [.result(text: nil, isError: false)]
        case "error", "stream_error":
            return [.result(text: errorMessage(in: msg), isError: true)]
        default:
            // session_configured, agent_reasoning, token counts, and whatever
            // a later release adds.
            return [.ignored]
        }
    }

    // MARK: - Shared

    /// The id a follow-up turn resumes. Only read from the fields Codex stamps
    /// it on, so an unrelated id elsewhere in the stream cannot be mistaken for
    /// a session; anything with whitespace in it is not one either.
    private static func sessionID(in object: [String: Any]) -> String? {
        var candidates: [Any?] = [
            object["thread_id"], object["session_id"], object["conversation_id"]
        ]
        if let thread = object["thread"] as? [String: Any] { candidates.append(thread["id"]) }
        if let msg = object["msg"] as? [String: Any] {
            candidates += [msg["session_id"], msg["thread_id"], msg["conversation_id"]]
        }
        for candidate in candidates {
            guard let id = candidate as? String else { continue }
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) { return trimmed }
        }
        return nil
    }

    /// The human-readable part of a failure, wherever this build put it.
    private static func errorMessage(in object: [String: Any]) -> String? {
        if let message = object["message"] as? String, !message.isEmpty { return message }
        if let error = object["error"] as? String, !error.isEmpty { return error }
        if let error = object["error"] as? [String: Any] {
            for key in ["message", "detail", "description"] {
                if let value = error[key] as? String, !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// One transcript line's worth of detail — commands and file lists both run
    /// long, and the transcript shows them inline.
    private static func shortened(_ value: String?) -> String? {
        guard let value else { return nil }
        let oneLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !oneLine.isEmpty else { return nil }
        return oneLine.count > 80 ? String(oneLine.prefix(80)) + "…" : oneLine
    }
}
