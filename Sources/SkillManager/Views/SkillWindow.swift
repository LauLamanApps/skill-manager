import SwiftUI

enum SkillWindow {
    static let id = "skill"
}

/// Hosts `SkillDetailView` in a window of its own, one per skill.
///
/// The window carries only the skill's id, never a `Skill` value: the store
/// re-scans from disk on every refresh and hands out fresh structs, so a
/// captured copy would go stale the moment the skill is saved, tagged or
/// synced. Resolving the id on each body evaluation keeps this window and the
/// card grid on the same record.
struct SkillWindowView: View {
    @EnvironmentObject var store: SkillStore
    let skillID: Skill.ID?

    private var skill: Skill? {
        guard let skillID else { return nil }
        return store.catalog.first { $0.id == skillID }
            ?? store.installed.first { $0.id == skillID }
    }

    var body: some View {
        if let skill {
            SkillDetailView(skill: skill)
        } else {
            // Reachable after the skill is uninstalled, renamed, or dropped by a
            // sync while its window is still open.
            ContentUnavailableView(
                "Skill Not Available",
                systemImage: "questionmark.folder",
                description: Text("It was removed or renamed. Close this window and open the skill again from the catalog.")
            )
            .navigationTitle("Skill")
        }
    }
}
