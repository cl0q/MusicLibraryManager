import Foundation

/// Preview of an m3u8 ingest operation — the diff between the incoming
/// playlist entries and the last snapshot for that (profile, playlist).
///
/// Produced by `PlaylistIngestService.preview(...)` and consumed by
/// `apply(preview:)` to mutate the DB playlist atomically.
struct IngestPreview {
    /// Resolved target playlist (id known, exists in DB).
    let targetPlaylistId: Int64
    /// Display name for the target playlist.
    let targetPlaylistName: String
    /// True when the target playlist was resolved but did not exist before
    /// (e.g. first import of a new playlist from the device).
    let willCreate: Bool

    /// Tracks that are in the incoming file but not in the snapshot.
    let added: [Entry]
    /// Tracks that are in the snapshot but not in the incoming file.
    let removed: [Entry]
    /// Tracks present in both but at a different position.
    let reordered: [Entry]

    /// Entries that could not be resolved to a library track.
    /// These are NEVER applied silently.
    let unresolved: [UnresolvedEntry]

    /// Whether the preview has any changes to apply.
    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && reordered.isEmpty
    }

    /// A resolved track entry in the preview.
    struct Entry: Identifiable, Hashable {
        let id: Int64          // track id
        let title: String
        let artist: String
        let uuid: String?      // mlm_uuid if known
        let path: String       // relative path from the m3u8
    }

    /// An entry that could not be resolved to a library track.
    struct UnresolvedEntry: Identifiable, Hashable {
        let id = UUID()
        let path: String
        let uuid: String?      // EXTMLM uuid if present
        let reason: String
    }
}
