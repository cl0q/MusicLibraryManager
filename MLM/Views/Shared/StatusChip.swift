import SwiftUI

/// A compact, text-labeled status indicator for track and job states.
@MainActor
struct StatusChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    init(text: String, systemImage: String, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    /// Returns no chip for the default local state.
    init?(availability: TrackAvailability) {
        switch availability {
        case .local:
            return nil
        case .downloading:
            self.init(text: "Downloading…", systemImage: "arrow.down.circle", tint: .mlmActive)
        case .notDownloaded:
            self.init(text: "Not downloaded", systemImage: "icloud", tint: .mlmInkMuted)
        case .failed:
            self.init(
                text: "Download failed",
                systemImage: "exclamationmark.arrow.circlepath",
                tint: .mlmAttention
            )
        case .fileMissing:
            self.init(text: "File missing", systemImage: "doc.questionmark", tint: .mlmError)
        }
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(MLMFont.badge)
            .foregroundStyle(tint)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(tint.opacity(0.15), in: Capsule())
            .accessibilityIdentifier("status_chip")
            .accessibilityLabel(text)
    }
}
