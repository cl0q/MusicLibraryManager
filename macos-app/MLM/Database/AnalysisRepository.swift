import Foundation
import GRDB

/// Repository for analysis data: fingerprints, artwork, replaygain, review queue.
final class AnalysisRepository: Sendable {
    private let database: DatabasePool

    init(database: DatabasePool) {
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
            var fp = fingerprint
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

    /// Save artwork metadata.
    func saveArtwork(_ artwork: Artwork) async throws {
        try await database.write { db in
            var art = artwork
            try art.save(db)
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
            var rg = replayGain
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
            var ta = analysis
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
}
