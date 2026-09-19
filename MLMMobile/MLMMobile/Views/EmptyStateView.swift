import SwiftUI

/// Friendly empty state when no manifest is found.
struct EmptyStateView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Library", systemImage: "music.note")
        } description: {
            VStack(spacing: 8) {
                Text("No mlm-library.json found.")
                    .font(.body)
                Text("Choose the sync folder from the toolbar, or import files via the Files app into this app's Documents directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } actions: {
            Text("Tip: Use the folder icon in the toolbar to pick your sync folder.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
