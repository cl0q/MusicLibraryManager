import Foundation

// `NewSyncProfileFromSelectionSheet` was merged into `NewSyncProfileSheet(trackIDs:)` (W3-SYNC:
// one sheet for both entry points, primary button `Create and Add ‹n› Tracks`).

/// Identifiable wrapper for track selections, used for robust sheet presentations in SwiftUI.
struct TrackSelectionContainer: Identifiable {
    let id = UUID()
    let trackIds: Set<Int64>
}
