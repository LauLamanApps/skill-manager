import Foundation

/// One event from an agent CLI's streaming output, reduced to the parts worth
/// showing while the run is still in flight.
///
/// The cases are agent-neutral — every CLI this app drives emits prose, tool
/// calls and a terminal result in some shape. Turning a given CLI's wire format
/// into these cases is the job of its `AgentRunner`.
enum AgentStreamEvent {
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
}

/// One decoded stream line: the events worth rendering, plus the session id the
/// CLI stamps on it, if any. The id is what a follow-up turn resumes.
///
/// A single line can carry several content blocks (text plus tool calls), hence
/// a list rather than one event.
struct AgentStreamLine {
    let events: [AgentStreamEvent]
    let sessionID: String?

    static let empty = AgentStreamLine(events: [], sessionID: nil)
}
