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

    @Test func keepResolutionAndUndoRestoreDuplicateMarkersAndHistory() async throws {
        let (database, analysis, tracks) = try makeRepositories()
        let firstID = try await insertTrack(database, title: "Master")
        let secondID = try await insertTrack(database, title: "Copy")
        let groupKey = "duplicate:\(firstID):\(secondID)"

        // An existing marker must be restored exactly after undo, rather than
        // simply clearing the group as a side effect of the resolution.
        try await tracks.markDuplicate(trackId: secondID, variantOf: firstID)
        let details = ReviewDetails(
            groupKey: groupKey,
            recommendation: ReviewRecommendation(action: .keepTrack, trackId: secondID),
            tracks: [
                ReviewTrackSnapshot(id: firstID, title: "Master", artist: "Artist"),
                ReviewTrackSnapshot(id: secondID, title: "Copy", artist: "Artist"),
            ]
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
                status: "pending",
                createdAt: nil,
                resolvedAt: nil
            )
        )

        try await analysis.applyReviewResolution(
            groupKey: groupKey,
            action: .keepManual,
            keptTrackIds: [secondID]
        )

        let resolved = try await analysis.fetchResolvedReviews()
        let resolvedFirst = try await tracks.fetchTrack(id: firstID)
        let resolvedSecond = try await tracks.fetchTrack(id: secondID)

        #expect(resolved.count == 1)
        #expect(resolved[0].reviewDetails?.resolutionSnapshot?.action == ReviewResolutionAction.keepManual.rawValue)
        #expect(resolvedFirst?.isDuplicate == 1)
        #expect(resolvedFirst?.variantOf == secondID)
        #expect(resolvedSecond?.isDuplicate == 0)
        #expect(resolvedSecond?.variantOf == nil)

        try await analysis.undoReviewResolution(groupKey: groupKey)

        let restored = try await analysis.fetchPendingReviews()
        let restoredFirst = try await tracks.fetchTrack(id: firstID)
        let restoredSecond = try await tracks.fetchTrack(id: secondID)

        #expect(restored.count == 1)
        #expect(restored[0].reviewDetails?.resolutionSnapshot == nil)
        #expect(restoredFirst?.isDuplicate == 0)
        #expect(restoredFirst?.variantOf == nil)
        #expect(restoredSecond?.isDuplicate == 1)
        #expect(restoredSecond?.variantOf == firstID)
    }

    @Test func metadataMergeUpdatesDatabaseOnlyAndUndoRestoresEveryField() async throws {
        let (database, analysis, tracks) = try makeRepositories()
        let firstID = try await insertTrack(database, title: "Song (Radio Edit)")
        let secondID = try await insertTrack(database, title: "Song")
        let groupKey = "duplicate:\(firstID):\(secondID)"

        try await database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET artist = ?, album_artist = ?, genre = ?, year = ? WHERE id = ?",
                arguments: ["Artist", "Artist", "Electronic", 2020, firstID]
            )
            try db.execute(
                sql: "UPDATE tracks SET artist = ?, album_artist = ?, genre = ?, year = ? WHERE id = ?",
                arguments: ["Artist feat. Guest", "Artist feat. Guest", "Dance", 2024, secondID]
            )
        }
        let first = try #require(await tracks.fetchTrack(id: firstID))
        let second = try #require(await tracks.fetchTrack(id: secondID))
        let details = ReviewDetails(
            groupKey: groupKey,
            conflictingFields: ["title", "artist", "genre", "year"],
            tracks: [ReviewTrackSnapshot(track: first), ReviewTrackSnapshot(track: second)]
        )
        try await analysis.saveReviewItem(
            ReviewItem(
                id: nil,
                actionType: "metadata_conflict",
                groupKey: groupKey,
                trackId: firstID,
                relatedTrackId: secondID,
                details: try details.encodedJSON(),
                autoAction: nil,
                status: "pending",
                createdAt: nil,
                resolvedAt: nil
            )
        )

        let merge = ReviewMetadataMerge(
            fields: [.title, .artist, .albumArtist, .genre, .year],
            source: second
        )
        try await analysis.applyReviewResolution(
            groupKey: groupKey,
            action: .mergeMetadata,
            metadataMerge: merge
        )

        let mergedFirst = try await tracks.fetchTrack(id: firstID)
        let mergedSecond = try await tracks.fetchTrack(id: secondID)
        #expect(mergedFirst?.title == "Song")
        #expect(mergedFirst?.artist == "Artist feat. Guest")
        #expect(mergedFirst?.genre == "Dance")
        #expect(mergedFirst?.year == 2024)
        #expect(mergedSecond?.title == "Song")
        #expect(try await analysis.fetchResolvedReviews().count == 1)

        try await analysis.undoReviewResolution(groupKey: groupKey)

        let restoredFirst = try await tracks.fetchTrack(id: firstID)
        let restoredSecond = try await tracks.fetchTrack(id: secondID)
        #expect(restoredFirst?.title == "Song (Radio Edit)")
        #expect(restoredFirst?.artist == "Artist")
        #expect(restoredFirst?.genre == "Electronic")
        #expect(restoredFirst?.year == 2020)
        #expect(restoredSecond?.title == "Song")
        #expect(restoredSecond?.artist == "Artist feat. Guest")
        #expect(restoredSecond?.genre == "Dance")
        #expect(restoredSecond?.year == 2024)
    }
}
