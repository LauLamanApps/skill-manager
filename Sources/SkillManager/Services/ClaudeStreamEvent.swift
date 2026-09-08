import Foundation

/// One line of `claude -p --output-format stream-json --verbose` output,
/// reduced to the parts worth showing while the run is still in flight.
///
/// The stream is newline-delimited JSON; each line is one event. Shapes that
/// carry no user-facing signal (hook callbacks, thinking-token counters, rate
/// limit notices) decode to `.ignored` and render nothing.
enum ClaudeStreamEvent {
    /// Assistant prose.
    case text(String)
    /// Assistant invoked a tool, with the most identifying argument if there is one.
    case toolUse(name: String, detail: String?)
    /// A tool came back with an error.
    case toolFailed
    /// Terminal event of the run. `text` is only set when the run failed.
    case result(text: String?, isError: Bool)
    /// A line that is not JSON at all — surfaced verbatim so nothing is swallowed.
    case raw(String)
    case ignored

    /// What to append to the running transcript, or nil when the event is silent.
    var displayText: String? {
        switch self {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .toolUse(let name, let detail):
            guard let detail, !detail.isEmpty else { return "⚙ \(name)" }
            return "⚙ \(name) \(detail)"
        case .toolFailed:
            return "⚠ tool call failed"
        case .result(let text, let isError):
            // On success the final result text just repeats the last assistant
            // message, which is already in the transcript.
            guard isError, let text, !text.isEmpty else { return nil }
            return text
        case .raw(let line):
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .ignored:
            return nil
        }
    }

    /// Decodes one stream line. A single line can carry several content blocks
    /// (text plus tool calls), so this returns an array.
    static func parse(line: String) -> ClaudeStreamLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ClaudeStreamLine(events: [], sessionID: nil) }
        guard
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ClaudeStreamLine(events: [.raw(trimmed)], sessionID: nil)
        }

        // The CLI stamps `session_id` on every line, whatever its type.
        let sessionID = object["session_id"] as? String
        let events: [ClaudeStreamEvent]
        switch object["type"] as? String {
        case "assistant":
            events = contentBlocks(of: object).compactMap(assistantEvent(forBlock:))
        case "user":
            // User-role lines carry tool results, including whole skill bodies
            // and file contents echoed back into the conversation. Only the
            // failure signal is worth showing.
            events = contentBlocks(of: object).compactMap(userEvent(forBlock:))
        case "result":
            let isError = (object["is_error"] as? Bool) ?? (object["subtype"] as? String != "success")
            events = [.result(text: object["result"] as? String, isError: isError)]
        default:
            events = [.ignored]
        }
        return ClaudeStreamLine(events: events, sessionID: sessionID)
    }

    private static func contentBlocks(of object: [String: Any]) -> [[String: Any]] {
        guard let message = object["message"] as? [String: Any] else { return [] }
        return message["content"] as? [[String: Any]] ?? []
    }

    private static func assistantEvent(forBlock block: [String: Any]) -> ClaudeStreamEvent? {
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

    private static func userEvent(forBlock block: [String: Any]) -> ClaudeStreamEvent? {
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

/// One decoded stream line: the events worth rendering, plus the session id the
/// CLI stamps on every line. The id is what a follow-up turn resumes.
struct ClaudeStreamLine {
    let events: [ClaudeStreamEvent]
    let sessionID: String?
}
