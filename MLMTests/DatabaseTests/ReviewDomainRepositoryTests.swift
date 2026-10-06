import Foundation
import GRDB
import Testing
@testable import MLM

@Suite("Review domain persistence")
struct ReviewDomainRepositoryTests {
    private final class CancellationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0

        func shouldCancel() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            checks += 1
            return checks > 1
        }
    }

    private func makeRepositories() throws -> (DatabaseQueue, AnalysisRepository, TrackRepository) {
        let database = try DatabaseManager.inMemory()
        return (
            database,
            AnalysisRepository(database: database),
            TrackRepository(database: database)
        )
    }

    private func insertTrack(_ database: DatabaseQueue, title: String) async throws -> Int64 {
        try await database.write { db in
            var track = Track(
                artist: "Artist",
                album: "Album",
                title: title,
                format: "flac",
                originalPath: "/\(title).flac"
            )
            try track.insert(db)
            return track.id!
        }
    }

    @Test func groupKeyMigrationAndGroupQueriesPreserveLegacyRows() async throws {
        let (database, analysis, _) = try makeRepositories()
        let firstID = try await insertTrack(database, title: "First")
        let secondID = try await insertTrack(database, title: "Second")
        let groupKey = "duplicate:\(firstID):\(secondID)"
        let details = ReviewDetails(
            groupKey: groupKey,
            evidence: ReviewEvidence(fingerprintSimilarity: 0.96),
            fieldScores: ReviewFieldScores(titleSimilarity: 1, artistSimilarity: 1),
            recommendation: ReviewRecommendation(action: .keepTrack, trackId: firstID),
            similarityScore: 0.96,
            trackA: ReviewTrackSnapshot(id: firstID, title: "First", artist: "Artist"),
            trackB: ReviewTrackSnapshot(id: secondID, title: "Second", artist: "Artist")
        )
        let groupedItem = ReviewItem(
            id: nil,
            actionType: "fingerprint_dedup",
            groupKey: groupKey,
            trackId: firstID,
            relatedTrackId: secondID,
            details: try details.encodedJSON(),
            autoAction: nil,
            status: "pending",
            createdAt: nil,
            resolvedAt: nil
        )
        let legacyItem = ReviewItem(
            id: nil,
            actionType: "metadata_conflict",
            trackId: secondID,
            relatedTrackId: firstID,
            details: "{}",
            autoAction: nil,
            status: "pending",
            createdAt: nil,
            resolvedAt: nil
        )

        try await analysis.saveReviewItems([groupedItem, legacyItem])

        let columns = try await database.read { try $0.columns(in: "review_queue").map(\.name) }
        let groups = try await analysis.fetchPendingReviewGroups()
        let groupedItems = try await analysis.fetchPendingReviews(groupKey: groupKey)

        #expect(columns.contains("group_key"))
        #expect(try await analysis.countPendingReviewGroups() == 2)
        #expect(try await analysis.countPendingReviewGroups(actionType: "fingerprint_dedup") == 1)
        #expect(groups.map(\.groupKey).contains(groupKey))
        #expect(groupedItems.count == 1)
        #expect(groupedItems[0].reviewDetails?.recommendation?.trackId == firstID)
    }

    @Test func unmarkDuplicateClearsExistingMarker() async throws {
        let (database, _, tracks) = try makeRepositories()
        let originalID = try await insertTrack(database, title: "Original")
        let duplicateID = try await insertTrack(database, title: "Duplicate")

        try await tracks.markDuplicate(trackId: duplicateID, variantOf: originalID)
        try await tracks.unmarkDuplicate(trackId: duplicateID)
        let track = try await tracks.fetchTrack(id: duplicateID)

        #expect(track?.isDuplicate == 0)
        #expect(track?.variantOf == nil)
    }

    @Test func inMemoryDatabaseDoesNotEnableForeignKeys() async throws {
        let (database, _, _) = try makeRepositories()
        let foreignKeys = try await database.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
        }

        #expect(foreignKeys == 0)
    }

    @Test func deepScanGroupsLegacyMarkedTracksWithoutChangingMarkers() async throws {
        let (database, analysis, tracks) = try makeRepositories()
        let firstID = try await insertTrack(database, title: "Same Song")
        let secondID = try await insertTrack(database, title: "Same Song (Copy)")
        let fingerprint = Data([0, 0, 0, 0])

        try await database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET duration = 180 WHERE id IN (?, ?)",
                arguments: [firstID, secondID]
            )
            try db.execute(
                sql: "UPDATE tracks SET is_duplicate = 1, variant_of = ? WHERE id = ?",
                arguments: [firstID, secondID]
            )
            try Fingerprint(
                trackId: firstID,
                fingerprint: fingerprint,
                durationSeconds: 180,
                acoustid: nil,
                musicbrainzRecordingId: nil,
                fingerprintedAt: nil
            ).insert(db)
            try Fingerprint(
                trackId: secondID,
                fingerprint: fingerprint,
                durationSeconds: 180,
                acoustid: nil,
                musicbrainzRecordingId: nil,
                fingerprintedAt: nil
            ).insert(db)
        }

        let result = try await DeepScanService(
            trackRepository: tracks,
            analysisRepository: analysis
        ).deepScan()
        let legacyMarkedTrack = try await tracks.fetchTrack(id: secondID)
        let reviews = try await analysis.fetchPendingReviews()

        #expect(result.duplicatesFound == 1)
        #expect(legacyMarkedTrack?.isDuplicate == 1)
        #expect(legacyMarkedTrack?.variantOf == firstID)
        #expect(reviews.count == 1)
        #expect(reviews[0].groupKey == "duplicate:\(firstID):\(secondID)")
        #expect(reviews[0].reviewDetails?.fieldScores?.titleSimilarity != nil)
        #expect(reviews[0].reviewDetails?.fieldScores?.artistSimilarity == 1)
    }

    @Test func cancelledReviewBatchRollsBackEveryProposal() async throws {
        let (database, analysis, _) = try makeRepositories()
        let firstID = try await insertTrack(database, title: "First")
        let secondID = try await insertTrack(database, title: "Second")
        let items = [
            ReviewItem(
                id: nil,
                actionType: "fingerprint_dedup",
                groupKey: "duplicate:1:2",
                trackId: firstID,
                relatedTrackId: secondID,
                details: "{}",
                autoAction: nil,
                status: "pending",
                createdAt: nil,
                resolvedAt: nil
            ),
            ReviewItem(
                id: nil,
                actionType: "fingerprint_dedup",
                groupKey: "duplicate:1:3",
                trackId: firstID,
                relatedTrackId: secondID,
                details: "{}",
                autoAction: nil,
                status: "pending",
                createdAt: nil,
                resolvedAt: nil
            ),
        ]
        let gate = CancellationGate()
        var cancelled = false

        do {
            try await analysis.saveReviewItems(items, shouldCancel: { gate.shouldCancel() })
        } catch is CancellationError {
            cancelled = true
        }

        let count = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_queue") ?? 0
        }
        #expect(cancelled)
        #expect(count == 0)
    }

    /// A decision made before v48 left a `resolutionSnapshot` on its rows; Restore puts every
    /// duplicate marker and metadata field back and returns the group to the pending queue.
    @Test func undoRestoresDuplicateMarkersAndMetadataFromAPreV48Snapshot() async throws {
        let (database, analysis, tracks) = try makeRepositories()
        let firstID = try await insertTrack(database, title: "Song (Radio Edit)")
        let secondID = try await insertTrack(database, title: "Song")
        let groupKey = "duplicate:\(firstID):\(secondID)"
        let first = try #require(await tracks.fetchTrack(id: firstID))
        let second = try #require(await tracks.fetchTrack(id: secondID))

        var details = ReviewDetails(
            groupKey: groupKey,
            tracks: [ReviewTrackSnapshot(track: first), ReviewTrackSnapshot(track: second)]
        )
        details.resolutionSnapshot = ReviewResolutionSnapshot(
            action: "keep_manual",
            keptTrackIds: [secondID],
            unkeptTrackIds: [firstID],
            duplicateStates: [
                ReviewDuplicateState(trackId: firstID, isDuplicate: 0, variantOf: nil),
                ReviewDuplicateState(trackId: secondID, isDuplicate: 1, variantOf: firstID),
            ],
            metadataStates: [ReviewTrackMetadataSnapshot(track: first), ReviewTrackMetadataSnapshot(track: second)]
        )
        try await analysis.saveReviewItem(
            ReviewItem(
                id: nil,
                actionType: "fingerprint_dedup",
                groupKey: groupKey,
                trackId: firstID,
                relatedTrackId: secondID,
                details: try details.encodedJSON(),
                autoAction: nil,
                status: "resolved",
                createdAt: nil,
                resolvedAt: nil
            )
        )
        // The state after the old decision: the markers flipped and a title changed.
        try await database.write { db in
            try db.execute(sql: "UPDATE tracks SET is_duplicate = 1, variant_of = ?, title = 'Changed' WHERE id = ?",
                           arguments: [secondID, firstID])
            try db.execute(sql: "UPDATE tracks SET is_duplicate = 0, variant_of = NULL WHERE id = ?",
                           arguments: [secondID])
        }

        try await analysis.undoReviewResolution(groupKey: groupKey)

        let restored = try await analysis.fetchPendingReviews()
        let restoredFirst = try await tracks.fetchTrack(id: firstID)
        let restoredSecond = try await tracks.fetchTrack(id: secondID)
        #expect(restored.count == 1)
        #expect(restored[0].reviewDetails?.resolutionSnapshot == nil)
        #expect(restoredFirst?.isDuplicate == 0)
        #expect(restoredFirst?.variantOf == nil)
        #expect(restoredFirst?.title == "Song (Radio Edit)")
        #expect(restoredSecond?.isDuplicate == 1)
        #expect(restoredSecond?.variantOf == firstID)
    }

    @Test func undoWithoutASnapshotThrows() async throws {
        let (_, analysis, _) = try makeRepositories()
        await #expect(throws: ReviewResolutionError.self) {
            try await analysis.undoReviewResolution(groupKey: "duplicate:1:2")
        }
    }
}
