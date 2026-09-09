import SwiftUI

/// Shown when `UpdateController` finds a newer release, with the release notes
/// rendered inline — iTerm's update prompt is the reference for this pattern.
struct UpdateAvailableSheet: View {
    let release: Release
    let onInstall: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Update Available").font(.title2).bold()
                Text("\(release.tagName) is ready to install.")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                ReleaseNoteBlocksView(blocks: noteBlocks)
                    .padding(12)
            }
            .frame(minHeight: 160, maxHeight: 320)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Later", action: onLater)
                Button("Install", action: onInstall)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var noteBlocks: [ReleaseNoteBlock] {
        guard let body = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
            return [.paragraph(text: AttributedString("No release notes provided."))]
        }
        return ReleaseNoteBlock.parse(body)
    }
}
