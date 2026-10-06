import Foundation
import GRDB

/// Read-only queries behind Info (W2-E): playlist membership of the selection, the source a
/// track is linked to, its duplicate reference and whether it has a similarity analysis.
struct InspectorQueries: Sendable {
    let database: any DatabaseReader

    /// A playlist that contains some of the selected tracks.
    struct Membership: Identifiable, Hashable, Sendable {
        let playlistID: Int64
        let name: String
        /// How many of the selected tracks it contains.
        let count: Int

        var id: Int64 { playlistID }
    }

    /// Playlists containing any of `trackIDs`, pinned first, then by name (the sidebar order).
    func memberships(trackIDs: [Int64]) async throws -> [Membership] {
        let ids = TrackTagRepository.uniqued(trackIDs)
        guard !ids.isEmpty else { return [] }
        return try await database.read { db in
            var counts: [Int64: Int] = [:]
            for batch in ids.chunked(into: 500) {
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
                for row in try Row.fetchAll(db, sql: """
                    SELECT playlist_id, COUNT(DISTINCT track_id) AS n FROM playlist_tracks
                    WHERE track_id IN (\(placeholders)) GROUP BY playlist_id
                    """, arguments: StatementArguments(batch)) {
                    counts[row["playlist_id"], default: 0] += row["n"] as Int
                }
            }
            guard !counts.isEmpty else { return [] }
            // The sidebar's order (`PlaylistRepository.fetchAll`, W3-PL; pinning is retired).
            return try PlaylistRepository.sidebarOrdered(db).compactMap { playlist in
                guard let id = playlist.id, let count = counts[id] else { return nil }
                return Membership(playlistID: id, name: playlist.name, count: count)
            }
        }
    }

    /// Stored names of the sources the track is linked to (`track_sources`).
    func sourceNames(trackID: Int64) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT s.name FROM track_sources ts JOIN sources s ON s.id = ts.source_id
                WHERE ts.track_id = ? ORDER BY ts.added_at
                """, arguments: [trackID])
        }
    }

    /// The track a duplicate points at.
    func track(id: Int64) async throws -> Track? {
        try await database.read { db in try Track.fetchOne(db, key: id) }
    }

    /// The track has the analysis `Similar` needs.
    func hasSimilarityAnalysis(trackID: Int64) async throws -> Bool {
        try await database.read { db in try TrackEmbedding.exists(db, key: trackID) }
    }
}
