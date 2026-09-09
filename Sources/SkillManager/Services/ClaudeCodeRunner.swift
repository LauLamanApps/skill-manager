import Foundation

/// `AgentRunner` for Claude Code — the reference implementation, and the only
/// agent whose behaviour is known to be correct end to end.
///
/// Its stream is newline-delimited JSON from
/// `claude -p --output-format stream-json --verbose`; each line is one event.
/// Shapes that carry no user-facing signal (hook callbacks, thinking-token
/// counters, rate limit notices) decode to `.ignored` and render nothing.
struct ClaudeCodeRunner: AgentRunner {
    let displayName = "Claude Code"
    let binaryName = "claude"

    /// How the CLI is invoked: a bare name resolved from the login shell PATH,
    /// or the absolute path the user configured.
    var launchPath: String = "claude"

    let supportsResume = true
    let trialLayout: TrialLayout? = .plugin
    let supportsToolCards = true

    /// `--verbose` is what makes `--output-format stream-json` legal together
    /// with `-p`; without it the CLI refuses to start. `plan` mode makes the
    /// CLI refuse edits outright, so Ask mode can't accidentally change a file.
    func command(resuming sessionID: String?, readOnly: Bool, model: String?) -> String {
        var parts = [
            quoted(launchPath), "-p", "--permission-mode", readOnly ? "plan" : "acceptEdits"
        ]
        if let sessionID { parts += ["--resume", sessionID] }
        if let model, !model.isEmpty { parts += ["--model", model] }
        parts += ["--output-format", "stream-json", "--verbose"]
        return parts.joined(separator: " ")
    }

    /// Haiku: the classification prompts this serves are short and mechanical,
    /// and the user is waiting on the answer inline.
    func oneShotCommand() -> String {
        "\(quoted(launchPath)) -p --model haiku"
    }

    /// The CLI has no "load just this skill" flag, but `--plugin-dir` loads a
    /// whole plugin directory for one session only — which is why the trial is
    /// built as a plugin around the skill.
    func trialCommand(_ trial: PreparedTrial, model: String?) -> String? {
        var command = "\(quoted(launchPath)) --plugin-dir \(quoted(trial.root.path))"
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

        // The CLI stamps `session_id` on every line, whatever its type. Only a
        // UUID is a real session — anything else is not something `--resume`
        // would accept.
        let sessionID = (object["session_id"] as? String)
            .flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
        let events: [AgentStreamEvent]
        switch object["type"] as? String {
        case "assistant":
            events = Self.contentBlocks(of: object).compactMap(Self.assistantEvent(forBlock:))
        case "user":
            // User-role lines carry tool results, including whole skill bodies
            // and file contents echoed back into the conversation. Only the
            // failure signal is worth showing.
            events = Self.contentBlocks(of: object).compactMap(Self.userEvent(forBlock:))
        case "result":
            let isError = (object["is_error"] as? Bool) ?? (object["subtype"] as? String != "success")
            events = [.result(text: object["result"] as? String, isError: isError)]
        default:
            events = [.ignored]
        }
        return AgentStreamLine(events: events, sessionID: sessionID)
    }

    private static func contentBlocks(of object: [String: Any]) -> [[String: Any]] {
        guard let message = object["message"] as? [String: Any] else { return [] }
        return message["content"] as? [[String: Any]] ?? []
    }

    private static func assistantEvent(forBlock block: [String: Any]) -> AgentStreamEvent? {
        switch block["type"] as? String {
        case "text":
            guard let text = block["text"] as? String else { return nil }
            return .text(text)
        case "tool_use":
            let name = block["name"] as? String ?? "tool"
            return .toolUse(name: name, detail: toolDetail(block["input"] as? [String: Any]))
        default:
            // thinking blocks and anything the CLI adds later
            return nil
        }
    }

    private static func userEvent(forBlock block: [String: Any]) -> AgentStreamEvent? {
        guard block["type"] as? String == "tool_result" else { return nil }
        return (block["is_error"] as? Bool) == true ? .toolFailed : nil
    }

    /// The one argument that best identifies what a tool call is doing.
    private static func toolDetail(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        let keys = ["file_path", "command", "pattern", "path", "query", "skill", "description", "url"]
        guard let value = keys.lazy.compactMap({ input[$0] as? String }).first else { return nil }
        let oneLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return oneLine.count > 80 ? String(oneLine.prefix(80)) + "…" : oneLine
    }
}
