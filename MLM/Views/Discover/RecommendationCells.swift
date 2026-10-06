import SwiftUI

/// What the rows of Discover ▸ Recommendations show beyond the track itself (V-INBOX.E06e).
/// `RecommendationsView` puts it into the environment of its `TrackListTable`; `TrackCell`
/// reads it for the `.source` column.
@MainActor
@Observable
final class RecommendationRowContext {
    /// Source word per track id (`SoundCloud`, `Last.fm`).
    var sources: [Int64: String] = [:]
}

extension EnvironmentValues {
    @Entry var recommendationRowContext: RecommendationRowContext? = nil
}

/// The source as a word with the 6 pt brand dot — not an upper-case capsule (V-INBOX.E06e, DEC-043).
struct RecommendationSourceCell: View {
    let rowID: Int64
    @Environment(\.recommendationRowContext) private var context

    var body: some View {
        if let source = context?.sources[rowID] {
            HStack(spacing: Spacing.xs) {
                SourceBrandDot(source: source)
                Text(source).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}
