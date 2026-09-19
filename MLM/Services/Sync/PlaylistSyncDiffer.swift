import Foundation

/// Input shape for a remote playlist entry (used by PlaylistSyncDiffer).
struct PlaylistDifferRemoteEntry {
    let externalID: String
    let title: String
    let artist: String
    let originalPath: String
}

/// Input shape for an existing local track (used by PlaylistSyncDiffer).
struct PlaylistDifferLocalTrack {
    let id: Int64
    let title: String
    let artist: String
    let originalPath: String?
    let externalIDs: [String]
}

/// Computes which tracks from a remote playlist are new (not yet in the local library).
enum PlaylistSyncDiffer {
    static func computeNewEntries(
        remote: [PlaylistDifferRemoteEntry],
        local: [PlaylistDifferLocalTrack]
    ) -> [PlaylistDifferRemoteEntry] {
        // Pre-compute lookup structures for O(1) tier-1 and tier-2 checks.
        let localExternalIDs: Set<String> = Set(local.flatMap(\.externalIDs))
        let localOriginalPaths: Set<String> = Set(
            local.compactMap { $0.originalPath?.isEmpty == false ? $0.originalPath : nil }
        )
        let localTitleArtist: Set<[String]> = Set(
            local
                .filter { !$0.title.isEmpty && !$0.artist.isEmpty }
                .map { [$0.title.lowercased(), $0.artist.lowercased()] }
        )

        return remote.filter { entry in
            // Tier 1: external ID match
            if !entry.externalID.isEmpty && localExternalIDs.contains(entry.externalID) {
                return false
            }
            // Tier 2: original path match (both non-empty)
            if !entry.originalPath.isEmpty && localOriginalPaths.contains(entry.originalPath) {
                return false
            }
            // Tier 3: title + artist match (both non-empty, case-insensitive)
            if !entry.title.isEmpty && !entry.artist.isEmpty {
                let key = [entry.title.lowercased(), entry.artist.lowercased()]
                if localTitleArtist.contains(key) {
                    return false
                }
            }
            return true
        }
    }
}
