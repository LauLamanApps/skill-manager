import SwiftUI

/// Shown while `UpdateController` is checking GitHub for a new release.
/// Not cancellable — the check is a single quick network round-trip.
struct UpdateCheckModal: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Checking for Updates…").font(.headline)
            ProgressView()
                .progressViewStyle(.linear)
                .frame(width: 220)
        }
        .padding(24)
        .frame(width: 280)
    }
}
