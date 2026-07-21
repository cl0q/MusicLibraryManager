import Foundation
import GRDB

/// Repository for analysis data: fingerprints, artwork, replaygain, review queue.
///
/// Accepts `any DatabaseWriter` so it works with both `DatabasePool` (production)
/// and `DatabaseQueue` (in-memory tests) — both conform to GRDB's `DatabaseWriter`.
final class AnalysisRepository: Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    // MARK: - Fingerprints

    /// Fetch fingerprint for a track.
    func fetchFingerprint(trackId: Int64) async throws -> Fingerprint? {
        try await database.read { db in
            try Fingerprint.fetchOne(db, key: trackId)
        }
    }

    /// Save a fingerprint.
    func saveFingerprint(_ fingerprint: Fingerprint) async throws {
        try await database.write { db in
            let fp = fingerprint
            try fp.save(db)
        }
    }

    // MARK: - Artwork

    /// Fetch artwork for a track.
    func fetchArtwork(trackId: Int64) async throws -> Artwork? {
        try await database.read { db in
            try Artwork.fetchOne(db, key: trackId)
        }
    }

    /// Fetch a retained provider URL even after the row's source is upgraded
    /// to embedded or cached SoundCloud artwork.
    func remoteArtworkURL(trackId: Int64) async throws -> String? {
        try await database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT remote_url FROM artwork WHERE track_id = ?",
                arguments: [trackId]
            )
        }
    }

    /// Save artwork metadata.
    func saveArtwork(_ artwork: Artwork) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO artwork (
                        track_id,
                        artwork_path,
                        source,
                        musicbrainz_release_group_id,
                        resolution,
                        fetched_at,
                        remote_url
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(track_id) DO UPDATE SET
                        artwork_path = excluded.artwork_path,
                        source = excluded.source,
                        musicbrainz_release_group_id = excluded.musicbrainz_release_group_id,
                        resolution = excluded.resolution,
                        fetched_at = excluded.fetched_at,
                        remote_url = COALESCE(excluded.remote_url, artwork.remote_url)
                    """,
                arguments: [
                    artwork.trackId,
                    artwork.artworkPath,
                    artwork.source,
                    artwork.musicbrainzReleaseGroupId,
                    artwork.resolution,
                    artwork.fetchedAt,
                    artwork.remoteUrl,
                ]
            )
        }
    }

    // MARK: - ReplayGain

    /// Fetch ReplayGain data for a track.
    func fetchReplayGain(trackId: Int64) async throws -> ReplayGain? {
        try await database.read { db in
            try ReplayGain.fetchOne(db, key: trackId)
        }
    }

    /// Save ReplayGain data.
    func saveReplayGain(_ replayGain: ReplayGain) async throws {
        try await database.write { db in
            let rg = replayGain
            try rg.save(db)
        }
    }

    // MARK: - Track Analysis

    /// Fetch analysis cache for a track.
    func fetchAnalysis(trackId: Int64) async throws -> TrackAnalysis? {
        try await database.read { db in
            try TrackAnalysis.fetchOne(db, key: trackId)
        }
    }

    /// Save analysis data.
    func saveAnalysis(_ analysis: TrackAnalysis) async throws {
        try await database.write { db in
            let ta = analysis
            try ta.save(db)
        }
    }

    // MARK: - Review Queue

    /// Fetch pending review items.
    func fetchPendingReviews() async throws -> [ReviewItem] {
        try await database.read { db in
            try ReviewItem
                .filter(ReviewItem.Columns.status == "pending")
                .order(ReviewItem.Columns.id.desc)
                .fetchAll(db)
        }
    }

    /// Count pending reviews.
    func countPendingReviews() async throws -> Int {
        try await database.read { db in
            try ReviewItem
                .filter(ReviewItem.Columns.status == "pending")
                .fetchCount(db)
        }
    }

    /// Resolve a review item.
    func resolveReview(id: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE review_queue SET status = 'resolved', resolved_at = datetime('now') WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Dismiss a review item.
    func dismissReview(id: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE review_queue SET status = 'dismissed', resolved_at = datetime('now') WHERE id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - Track Tags

    /// Fetch tags for a track.
    func fetchTags(trackId: Int64) async throws -> [TrackTag] {
        try await database.read { db in
            try TrackTag
                .filter(TrackTag.Columns.trackId == trackId)
                .fetchAll(db)
        }
    }

    /// Set a tag on a track.
    func setTag(trackId: Int64, key: String, value: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO track_tags (track_id, tag_key, tag_value) VALUES (?, ?, ?)",
                arguments: [trackId, key, value]
            )
        }
    }

    /// Remove a tag from a track.
    func removeTag(trackId: Int64, key: String, value: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM track_tags WHERE track_id = ? AND tag_key = ? AND tag_value = ?",
                arguments: [trackId, key, value]
            )
        }
    }

    // MARK: - Review Queue (Write)

    /// Save a review item.
    func saveReviewItem(_ item: ReviewItem) async throws {
        try await database.write { db in
            var review = item
            try review.insert(db)
        }
    }

    // MARK: - Batch Queries

    /// Fetch all tracks missing fingerprints.
    func fetchUnfingerprintedTrackIds() async throws -> [Int64] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id FROM tracks t
                LEFT JOIN fingerprints f ON f.track_id = t.id
                WHERE f.track_id IS NULL AND t.organized_path IS NOT NULL
            """)
            return rows.compactMap { $0["id"] as? Int64 }
        }
    }

    /// Fetch all tracks missing ReplayGain analysis.
    func fetchUnanalyzedTrackIds() async throws -> [Int64] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id FROM tracks t
                LEFT JOIN replaygain r ON r.track_id = t.id
                WHERE r.track_id IS NULL AND t.organized_path IS NOT NULL
            """)
            return rows.compactMap { $0["id"] as? Int64 }
        }
    }
}
