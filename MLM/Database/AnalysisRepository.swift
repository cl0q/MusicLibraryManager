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

    /// Fetch all artwork rows that have a non-empty `artwork_path`.
    ///
    /// Used by `ArtworkBackfillService.reconcileDanglingArtworkFiles()` to detect
    /// rows whose cached file no longer exists on disk.
    func fetchAllArtworkPaths() async throws -> [(trackId: Int64, artworkPath: String)] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT track_id, artwork_path FROM artwork
                WHERE artwork_path IS NOT NULL AND artwork_path <> ''
            """)
            return rows.map { row in
                (trackId: row["track_id"] as Int64, artworkPath: row["artwork_path"] as String)
            }
        }
    }

    /// Mark artwork files as missing: clear `artwork_path` and `resolution`,
    /// set `source = 'missing'`. Preserves `remote_url` and
    /// `musicbrainz_release_group_id` so provider lookups still work.
    ///
    /// Batches the ids in chunks of 500 to avoid building one enormous statement.
    func markArtworkFilesMissing(trackIds: [Int64]) async throws {
        guard !trackIds.isEmpty else { return }
        let chunkSize = 500
        try await database.write { db in
            for chunkStart in stride(from: 0, to: trackIds.count, by: chunkSize) {
                let chunk = Array(trackIds[chunkStart..<min(chunkStart + chunkSize, trackIds.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                try db.execute(
                    sql: """
                        UPDATE artwork
                        SET artwork_path = NULL, resolution = NULL, source = 'missing'
                        WHERE track_id IN (\(placeholders))
                    """,
                    arguments: StatementArguments(chunk)
                )
            }
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
        try await fetchReviews(status: "pending")
    }

    /// Fetch completed review decisions. Legacy status-only dismissals remain
    /// visible as history, while current resolved rows retain an undo snapshot.
    func fetchResolvedReviews() async throws -> [ReviewItem] {
        try await database.read { db in
            try ReviewItem.fetchAll(
                db,
                sql: "SELECT * FROM review_queue WHERE status IN ('resolved', 'dismissed') ORDER BY id DESC"
            )
        }
    }

    private func fetchReviews(status: String) async throws -> [ReviewItem] {
        try await database.read { db in
            try ReviewItem
                .filter(ReviewItem.Columns.status == status)
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

    /// Fetch pending groups. Legacy pair-only rows remain individual groups,
    /// identified by their stable queue row ID.
    func fetchPendingReviewGroups() async throws -> [ReviewQueueGroup] {
        try await database.read { db in
            try ReviewQueueGroup.fetchAll(db, sql: """
                SELECT
                    COALESCE(group_key, 'legacy:' || id) AS group_key,
                    MIN(action_type) AS action_type,
                    COUNT(*) AS item_count,
                    MAX(created_at) AS latest_created_at
                FROM review_queue
                WHERE status = 'pending'
                GROUP BY COALESCE(group_key, 'legacy:' || id)
                ORDER BY MAX(id) DESC
            """)
        }
    }

    /// Fetch all pending queue rows belonging to one review group.
    func fetchPendingReviews(groupKey: String) async throws -> [ReviewItem] {
        try await database.read { db in
            try ReviewItem.fetchAll(db, sql: """
                SELECT * FROM review_queue
                WHERE status = 'pending' AND group_key = ?
                ORDER BY id DESC
            """, arguments: [groupKey])
        }
    }

    /// Count pending review groups, optionally restricted to one action type.
    func countPendingReviewGroups(actionType: String? = nil) async throws -> Int {
        try await database.read { db in
            let actionFilter = actionType.map { _ in " AND action_type = ?" } ?? ""
            let arguments = actionType.map { StatementArguments([$0]) } ?? StatementArguments()
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT COALESCE(group_key, 'legacy:' || id)
                    FROM review_queue
                    WHERE status = 'pending'
                    \(actionFilter)
                    GROUP BY COALESCE(group_key, 'legacy:' || id)
                )
            """, arguments: arguments) ?? 0
        }
    }

    /// Counts use groups instead of pair rows so the sidebar reports the same
    /// units that the Review screen presents to the user.
    func pendingReviewCounts() async throws -> (duplicates: Int, conflicts: Int) {
        async let duplicates = countPendingReviewGroups(actionType: "fingerprint_dedup")
        async let conflicts = countPendingReviewGroups(actionType: "metadata_conflict")
        return try await (duplicates, conflicts)
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

    /// Persist a complete scan atomically. Cancellation is checked inside the
    /// transaction so a cancelled scan cannot leave a subset of its groups.
    func saveReviewItems(
        _ items: [ReviewItem],
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) async throws {
        guard !items.isEmpty else { return }
        try await database.write { db in
            // `DatabaseWriter.write` already executes in a transaction. A
            // thrown cancellation rolls back every insert in this batch.
            for item in items {
                guard !shouldCancel() else { throw CancellationError() }
                var review = item
                try review.insert(db)
            }
        }
    }

    /// Replace only pending scan proposals in one transaction. Historical
    /// resolutions are intentionally retained, and cancellation rolls back the
    /// delete as well as every new proposal.
    ///
    /// Decisions are sticky (IMP-051, PP-SOURCES-01): a proposed group is dropped silently
    /// unless it contains at least one pair of tracks no decision covers, and a group whose key
    /// equals an already resolved one (decisions from before `v48`, which recorded no pairs) is
    /// dropped too. Returns what was actually proposed.
    @discardableResult
    func replacePendingScanReviewItems(
        _ items: [ReviewItem],
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) async throws -> (duplicates: Int, conflicts: Int) {
        try await database.write { db in
            guard !shouldCancel() else { throw CancellationError() }
            try db.execute(
                sql: """
                    DELETE FROM review_queue
                    WHERE status = 'pending'
                      AND action_type IN ('fingerprint_dedup', 'metadata_conflict')
                    """
            )
            let decided = try ReviewDecisionRepository.decidedPairs(db)
            let resolvedKeys = Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT group_key FROM review_queue
                WHERE status IN ('resolved', 'dismissed') AND group_key IS NOT NULL
                """))
            var duplicates = 0
            var conflicts = 0
            for item in items {
                guard !shouldCancel() else { throw CancellationError() }
                let members = Array(Self.trackIDs(for: [item])).sorted()
                if let key = item.groupKey, resolvedKeys.contains(key) { continue }
                if members.count > 1, !ReviewPair.hasUndecidedPair(members, decided: decided) { continue }
                var review = item
                try review.insert(db)
                if item.actionType == "metadata_conflict" { conflicts += 1 } else { duplicates += 1 }
            }
            return (duplicates, conflicts)
        }
    }

    // MARK: - Review Resolution

    /// Applies a review decision and its undo snapshot in the same database
    /// transaction. Resolution changes database metadata only; it never moves,
    /// renames, deletes, or trashes a media file.
    func applyReviewResolution(
        groupKey: String,
        action: ReviewResolutionAction,
        keptTrackIds: [Int64] = [],
        metadataMerge: ReviewMetadataMerge? = nil
    ) async throws {
        try await database.write { db in
            let items = try Self.reviewItems(db: db, groupKey: groupKey, status: "pending")
            guard !items.isEmpty else { throw ReviewResolutionError.missingPendingGroup }

            let trackIDs = Self.trackIDs(for: items)
            let tracks = try Track.filter(trackIDs.contains(Track.Columns.id)).fetchAll(db)
            let tracksByID = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
                track.id.map { ($0, track) }
            })
            let orderedTrackIDs = trackIDs.sorted()
            let availableTrackIDs = orderedTrackIDs.filter { tracksByID[$0] != nil }

            let kept = Array(Set(keptTrackIds)).sorted()
            if action == .keepRecommended || action == .keepManual {
                guard kept.count == 1, availableTrackIDs.contains(kept[0]) else {
                    throw ReviewResolutionError.invalidKeepSelection
                }
            }

            let duplicateStates = availableTrackIDs.compactMap { id in
                tracksByID[id].map {
                    ReviewDuplicateState(trackId: id, isDuplicate: $0.isDuplicate, variantOf: $0.variantOf)
                }
            }
            let metadataStates = availableTrackIDs.compactMap { id in
                tracksByID[id].map(ReviewTrackMetadataSnapshot.init(track:))
            }
            let unkept = availableTrackIDs.filter { !kept.contains($0) }
            let snapshot = ReviewResolutionSnapshot(
                action: action.rawValue,
                keptTrackIds: kept,
                unkeptTrackIds: unkept,
                duplicateStates: duplicateStates,
                metadataStates: metadataStates
            )

            switch action {
            case .keepRecommended, .keepManual:
                let keptID = kept[0]
                for trackID in availableTrackIDs {
                    if trackID == keptID {
                        try db.execute(
                            sql: "UPDATE tracks SET is_duplicate = 0, variant_of = NULL WHERE id = ?",
                            arguments: [trackID]
                        )
                    } else {
                        try db.execute(
                            sql: "UPDATE tracks SET is_duplicate = 1, variant_of = ? WHERE id = ?",
                            arguments: [keptID, trackID]
                        )
                    }
                }

            case .keepAll, .mergeMetadata:
                for trackID in availableTrackIDs {
                    try db.execute(
                        sql: "UPDATE tracks SET is_duplicate = 0, variant_of = NULL WHERE id = ?",
                        arguments: [trackID]
                    )
                }

            case .dismiss:
                break
            }

            if action == .mergeMetadata, let metadataMerge {
                for trackID in availableTrackIDs {
                    guard var track = tracksByID[trackID] else { continue }
                    Self.apply(metadataMerge, to: &track)
                    track.searchText = DatabaseManager.foldedSearchText(track.rawSearchText)
                    try track.update(db)
                }
            }

            for index in items.indices {
                var item = items[index]
                var details = item.reviewDetails ?? ReviewDetails(
                    groupKey: groupKey,
                    tracks: availableTrackIDs.compactMap { tracksByID[$0].map(ReviewTrackSnapshot.init(track:)) }
                )
                details.resolutionSnapshot = snapshot
                item.details = try details.encodedJSON()
                item.status = "resolved"
                try item.update(db)
            }
            try Self.updateReviewStatus(db: db, groupKey: groupKey, status: "resolved", resolvedAt: true)
        }
    }

    /// Restores duplicate markers and metadata from the resolution snapshot,
    /// then returns the group to the pending queue in one transaction.
    func undoReviewResolution(groupKey: String) async throws {
        try await database.write { db in
            let items = try Self.reviewItems(db: db, groupKey: groupKey, status: "resolved")
            guard let snapshot = items.compactMap(\.reviewDetails?.resolutionSnapshot).first else {
                throw ReviewResolutionError.missingSnapshot
            }

            for state in snapshot.duplicateStates ?? [] {
                try db.execute(
                    sql: "UPDATE tracks SET is_duplicate = ?, variant_of = ? WHERE id = ?",
                    arguments: [state.isDuplicate, state.variantOf, state.trackId]
                )
            }

            for state in snapshot.metadataStates ?? [] {
                guard var track = try Track.fetchOne(db, id: state.trackId) else { continue }
                track.title = state.title
                track.artist = state.artist
                track.albumArtist = state.albumArtist
                track.album = state.album
                track.genre = state.genre
                track.year = state.year
                track.searchText = DatabaseManager.foldedSearchText(track.rawSearchText)
                try track.update(db)
            }

            for index in items.indices {
                var item = items[index]
                guard var details = item.reviewDetails else { continue }
                details.resolutionSnapshot = nil
                item.details = try details.encodedJSON()
                item.status = "pending"
                try item.update(db)
            }
            try Self.updateReviewStatus(db: db, groupKey: groupKey, status: "pending", resolvedAt: false)
        }
    }

    private static func reviewItems(
        db: Database,
        groupKey: String,
        status: String
    ) throws -> [ReviewItem] {
        if let legacyID = legacyReviewID(from: groupKey) {
            return try ReviewItem.fetchAll(
                db,
                sql: "SELECT * FROM review_queue WHERE id = ? AND status = ?",
                arguments: [legacyID, status]
            )
        }
        return try ReviewItem.fetchAll(
            db,
            sql: "SELECT * FROM review_queue WHERE group_key = ? AND status = ? ORDER BY id DESC",
            arguments: [groupKey, status]
        )
    }

    private static func updateReviewStatus(
        db: Database,
        groupKey: String,
        status: String,
        resolvedAt: Bool
    ) throws {
        let timeSQL = resolvedAt ? "datetime('now')" : "NULL"
        if let legacyID = legacyReviewID(from: groupKey) {
            try db.execute(
                sql: "UPDATE review_queue SET status = ?, resolved_at = \(timeSQL) WHERE id = ?",
                arguments: [status, legacyID]
            )
        } else {
            try db.execute(
                sql: "UPDATE review_queue SET status = ?, resolved_at = \(timeSQL) WHERE group_key = ?",
                arguments: [status, groupKey]
            )
        }
    }

    private static func legacyReviewID(from groupKey: String) -> Int64? {
        guard groupKey.hasPrefix("legacy:") else { return nil }
        return Int64(groupKey.dropFirst("legacy:".count))
    }

    private static func trackIDs(for items: [ReviewItem]) -> Set<Int64> {
        var ids = Set(items.flatMap { item in
            [item.trackId, item.relatedTrackId].compactMap { $0 }
        })
        for item in items {
            ids.formUnion(item.reviewDetails?.tracks.map(\.id) ?? [])
        }
        return ids
    }

    private static func apply(_ merge: ReviewMetadataMerge, to track: inout Track) {
        for field in merge.fields {
            switch field {
            case .title: track.title = merge.title
            case .artist: track.artist = merge.artist
            case .albumArtist: track.albumArtist = merge.albumArtist
            case .album: track.album = merge.album
            case .genre: track.genre = merge.genre
            case .year: track.year = merge.year
            }
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

enum ReviewResolutionError: LocalizedError {
    case invalidKeepSelection
    case missingPendingGroup
    case missingSnapshot

    var errorDescription: String? {
        switch self {
        case .invalidKeepSelection:
            "Choose one version to keep before resolving this group."
        case .missingPendingGroup:
            "This review is no longer pending. Refresh Review and try again."
        case .missingSnapshot:
            "This review cannot be restored because its undo data is unavailable."
        }
    }
}
