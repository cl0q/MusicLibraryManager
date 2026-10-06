import Foundation

/// Which tracks the library's lists show (IMP-049, W3-REV).
///
/// A version hidden by a Review decision (`is_duplicate = 1`) stays in the library — on disk, in
/// playlists that kept it, in Genres, Folders, the queue and sync — but no longer appears in
/// **All Tracks** or in **search results** (nor, later, in albums). It stays reachable through
/// Review ▸ Resolved and comes back with `Restore`.
///
/// Apply `listedSQL` only where a list is *the library as a whole* (`TrackScopeQueries`,
/// `TrackSearchQueries`, `TrackRepository.fetchTracks(scope:search:)`); a container's own
/// listing (playlist, genre, folder) does not use it.
enum TrackVisibility {
    /// SQL predicate over `tracks`: the row is listed.
    static let listedSQL = "tracks.is_duplicate = 0"

    /// `predicate AND listed`.
    static func listed(_ predicate: String) -> String {
        "(\(predicate)) AND \(listedSQL)"
    }
}
