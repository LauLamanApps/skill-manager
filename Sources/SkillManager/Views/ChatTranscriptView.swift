import SwiftUI

/// Renders a `ClaudeRunner` conversation as a list of turns — each user
/// instruction with the output it produced — and keeps the newest line in
/// view while a run is streaming.
struct ChatTranscriptView: View {
    let turns: [ClaudeRunner.ChatTurn]
    let isRunning: Bool

    private let bottomAnchor = "chat-transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        turnView(turn, isLast: index == turns.count - 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id(bottomAnchor)
            }
            .onChange(of: scrollKey) { _, _ in
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func turnView(_ turn: ClaudeRunner.ChatTurn, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(turn.prompt, systemImage: "person.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if turn.output.isEmpty {
                if isLast, isRunning {
                    Text("Claude Code is working…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(turn.output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Cheap stand-in for "the transcript grew" — the turns themselves are not
    /// Equatable, and only the tail ever changes.
    private var scrollKey: String {
        "\(turns.count)-\(turns.last?.output.count ?? 0)"
    }
}
