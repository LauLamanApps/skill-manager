import Foundation
import SwiftUI

/// Keeps one `ClaudeRunner` alive per chat surface for as long as the app runs.
///
/// The views that show a conversation are short-lived: the detail column is
/// rebuilt with a fresh identity on every skill switch, and a sheet is torn
/// down when it closes. A runner owned by such a view dies with it, taking the
/// transcript, the resumable session id and the pending diff along. Holding the
/// runners here instead means navigating away from a skill and back re-attaches
/// to the same conversation — including one that is still streaming.
///
/// Deliberately publishes nothing: views observe the individual runner they
/// were handed, so looking one up while a body is being evaluated is safe.
@MainActor
final class ChatSessionStore: ObservableObject {
    /// Identifies a conversation. The raw value is only ever used as a
    /// dictionary key, so the two surfaces of the same skill stay separate.
    enum Key: Hashable {
        /// Chat panel below the editor, per skill.
        case detail(Skill.ID)
        /// "Edit with AI" sheet, per skill.
        case edit(Skill.ID)
        /// "New Skill with AI" sheet — one shared conversation.
        case newSkill
    }

    private var runners: [Key: ClaudeRunner] = [:]

    /// The conversation for `key`, resumed if it exists and created otherwise.
    func runner(for key: Key) -> ClaudeRunner {
        if let existing = runners[key] { return existing }
        pruneEmpty(keeping: key)
        let runner = ClaudeRunner()
        runners[key] = runner
        return runner
    }

    /// Drops runners nobody would miss — merely visiting a skill creates one,
    /// so without this the dictionary grows by one entry per skill opened.
    private func pruneEmpty(keeping key: Key) {
        runners = runners.filter { $0.key == key || $0.value.hasRestorableState }
    }
}
