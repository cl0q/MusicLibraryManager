import Foundation

/// The top-level library manifest written by MLM to the sync profile output root.
/// Schema version 1 per IOS_SIDECAR_PLAN.md §3.
struct LibraryManifest: Codable, Equatable {
    let schema: Int
    let profile: String
    let generatedAt: String
    let tracks: [ManifestTrack]
    let playlists: [ManifestPlaylist]

    enum CodingKeys: String, CodingKey {
        case schema
        case profile
        case generatedAt = "generated_at"
        case tracks
        case playlists
    }
}
