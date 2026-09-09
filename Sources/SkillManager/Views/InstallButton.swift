import SwiftUI

/// Install control for one or more catalog skills.
///
/// With a single agent enabled there is nothing to choose, so this stays a plain
/// button; a menu would add a click to the common case. With several enabled it
/// becomes a picker offering each agent individually plus all of them at once.
struct InstallButton: View {
    @EnvironmentObject var store: SkillStore
    let skills: [Skill]
    let title: String
    var systemImage: String = "arrow.down.circle"
    var onComplete: () -> Void = {}

    var body: some View {
        let targets = store.enabledTargets
        if targets.count > 1 {
            Menu {
                ForEach(targets) { target in
                    Button {
                        store.install(skills, into: [target])
                        onComplete()
                    } label: {
                        Label(target.kind.displayName, systemImage: target.kind.icon)
                    }
                }
                Divider()
                Button {
                    store.install(skills, into: targets)
                    onComplete()
                } label: {
                    Label("All Enabled Agents", systemImage: "square.stack.3d.up.fill")
                }
            } label: {
                Label(title, systemImage: systemImage)
            }
        } else {
            Button {
                store.install(skills, into: targets)
                onComplete()
            } label: {
                Label(title, systemImage: systemImage)
            }
            .disabled(targets.isEmpty)
            .help(targets.isEmpty
                  ? "Enable an agent in Settings › Installed Skills first"
                  : "Install into \(targets[0].kind.displayName)")
        }
    }
}
