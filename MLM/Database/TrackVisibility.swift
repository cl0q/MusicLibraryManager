import Foundation

/// Which tracks the library's lists show (IMP-049, W3-REV).
///
/// A version hidden by a Review decision (`hidden_by_review = 1`, v54 — never `is_duplicate`, which older scans set without a decision) stays in the library — on disk, in
/// playlists that kept it, in Genres, Folders, the queue and sync — but no longer appears in
/// **All Tracks** or in **search results** (nor, later, in albums). It stays reachable through
/// Review ▸ Resolved and comes back with `Restore`.
///
/// A *held recommendation* (`is_pending_recommendation = 1`, v49, IMP-053) is a downloaded
/// suggestion waiting in Discover ▸ Recommendations; it is listed nowhere else until it is kept.
/// (A dismissed one keeps the flag, so it stays out of every list until the next launch purges it.)
///
/// Apply `listedSQL` only where a list is *the library as a whole* (`TrackScopeQueries`,
/// `TrackSearchQueries`, `TrackRepository.fetchTracks(scope:search:)`); a container's own
/// listing (playlist, genre, folder) does not use it.
enum TrackVisibility {
    /// SQL predicate over `tracks`: the row is listed.
    static let listedSQL = "tracks.hidden_by_review IS NOT 1 AND tracks.is_pending_recommendation IS NOT 1"

    /// `predicate AND listed`.
    static func listed(_ predicate: String) -> String {
        "(\(predicate)) AND \(listedSQL)"
    }
}
