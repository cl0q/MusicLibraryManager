import Foundation
import GRDB
import Testing
@testable import MLM

/// The Review nits of W5-F2 (IMP-108): legacy keys become stable keys at the next scan, a library
/// switch drops a running scan, and Resolved says what was decided.
@Suite("ReviewNitsTests", .serialized)
@MainActor
struct ReviewNitsTests {

    // MARK: legacy:<rowid>

    private func insertLegacy(_ db: DatabaseQueue, track: Int64, related: Int64?, status: String, action: String = "fingerprint_dedup") async throws -> Int64 {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO review_queue (action_type, group_key, track_id, related_track_id, details, status)
                VALUES (?, NULL, ?, ?, '{}', ?)
                """, arguments: [action, track, related, status])
            return db.lastInsertedRowID
        }
    }

    @Test func aRescanGivesLegacyRowsTheStableKeyOfTheirPair() async throws {
        let env = try ReviewEnv.make()
        let pending = try await insertLegacy(env.db, track: 7, related: 3, status: "pending")
        let resolved = try await insertLegacy(env.db, track: 9, related: 4, status: "resolved")
        let lone = try await insertLegacy(env.db, track: 11, related: nil, status: "resolved")
        let other = try await insertLegacy(env.db, track: 1, related: 2, status: "pending", action: "something_else")

        try await AnalysisRepository(database: env.db).replacePendingScanReviewItems([])

        let rows = try await env.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, group_key FROM review_queue ORDER BY id")
        }
        let keys = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, $0["group_key"] as String?) })
        #expect(keys[pending] == nil, "the pending proposal was replaced by the scan")
        #expect(keys[resolved] == "duplicate:4:9", "resolved history gets the pair's stable key")
        #expect(keys[lone] == .some(nil), "no pair, no key")
        #expect(keys[other] == .some(nil), "other kinds of rows are not touched")
    }

    @Test func aLegacyKeyNoLongerAddressesAStampedRow() async throws {
        let env = try ReviewEnv.make()
        let resolved = try await insertLegacy(env.db, track: 9, related: 4, status: "resolved")
        let analysis = AnalysisRepository(database: env.db)
        try await analysis.replacePendingScanReviewItems([])

        // The old key finds nothing any more (the row answers to its stable key).
        await #expect(throws: (any Error).self) {
            try await analysis.undoReviewResolution(groupKey: "legacy:\(resolved)")
        }
        let status = try await env.db.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM review_queue WHERE id = ?", arguments: [resolved])
        }
        #expect(status == "resolved")

        let items = ReviewGroup.groups(from: try await analysis.fetchResolvedReviews())
        #expect(items.map(\.key) == ["duplicate:4:9"])
    }

    @Test func aStampedPairIsNotProposedAgainAfterItsResolvedRowGotItsKey() async throws {
        let env = try ReviewEnv.make()
        _ = try await insertLegacy(env.db, track: 9, related: 4, status: "resolved")
        let proposal = ReviewItem(id: nil, actionType: "fingerprint_dedup", groupKey: "duplicate:4:9", trackId: 9,
                                  relatedTrackId: 4, details: "{}", autoAction: nil, status: "pending",
                                  createdAt: nil, resolvedAt: nil)
        let proposed = try await AnalysisRepository(database: env.db).replacePendingScanReviewItems([proposal])
        #expect(proposed.duplicates == 0, "decided before: sticky (IMP-051)")
    }

    // MARK: Library switch mid-scan

    private func runner(_ env: ReviewEnv, gate: ReviewScanRunnerTests.Gate, libraryID: @escaping @MainActor () -> String?) -> ReviewScanRunner {
        ReviewScanRunner(center: env.center, config: { env.config }, scan: {
            { progress in
                progress(1, 10)
                await gate.wait()
                return DeepScanService.DeepScanResult(pairsCompared: 10, duplicatesFound: 4, conflictsFlagged: 0)
            }
        }, didChange: {}, libraryID: libraryID)
    }

    @Test func aLibrarySwitchCancelsTheScanAndKeepsItsResultFromTheNextLibrary() async throws {
        let env = try ReviewEnv.make()
        let gate = ReviewScanRunnerTests.Gate()
        let runner = runner(env, gate: gate) { "lib-a" }
        #expect(runner.start())
        runner.libraryDidChange()
        gate.release()
        await runner.waitUntilIdle()
        #expect(runner.lastScan == nil)
        #expect(try await env.config.get(key: ReviewLastScan.keyDate) == nil, "nothing written to the config")
        #expect(env.center.finishedOperations.first { $0.kind == .duplicateScan }?.state == .cancelled)
        #expect(!runner.isActive)
    }

    @Test func aScanThatEndsInAnotherLibraryDiscardsItsResult() async throws {
        let env = try ReviewEnv.make()
        let gate = ReviewScanRunnerTests.Gate()
        var current = "lib-a"
        let runner = runner(env, gate: gate) { current }
        #expect(runner.start())
        current = "lib-b"
        gate.release()
        await runner.waitUntilIdle()
        #expect(runner.lastScan == nil)
        #expect(try await env.config.get(key: ReviewLastScan.keyDate) == nil)
        #expect(env.center.finishedOperations.first { $0.kind == .duplicateScan }?.state == .cancelled)
    }

    @Test func aLibraryChangeWithNoScanRunningDoesNothingAndTheNextScanRunsNormally() async throws {
        let env = try ReviewEnv.make()
        let gate = ReviewScanRunnerTests.Gate()
        let runner = runner(env, gate: gate) { "lib-a" }
        runner.libraryDidChange()
        gate.release()
        #expect(runner.start())
        await runner.waitUntilIdle()
        #expect(runner.lastScan?.duplicateGroups == 4)
    }

    // MARK: Decision column

    private func record(_ action: ReviewDecisionAction) -> ReviewDecisionRecord {
        ReviewDecisionRecord(id: 1, groupKey: "duplicate:1:2", kind: .duplicate, action: action, keptTrackID: 1,
                             unkeptMode: .hidden, consequences: ReviewDecisionConsequences(), decidedAt: "2026-10-03 17:02:00")
    }

    @Test func theDecisionWordsAreTheMockupsAndAnOldDecisionShowsADash() {
        #expect(ReviewPresentation.decisionWord(record(.keepRecommended)) == "Kept recommended")
        #expect(ReviewPresentation.decisionWord(record(.keepSelected)) == "Kept selected")
        #expect(ReviewPresentation.decisionWord(record(.keepAll)) == "Not duplicates")
        #expect(ReviewPresentation.decisionWord(record(.keepBoth)) == "Not duplicates")
        #expect(ReviewPresentation.decisionWord(record(.merge)) == "Merged")
        #expect(ReviewPresentation.decisionWord(nil) == "—")
        #expect(ReviewPresentation.albumSetWord == "Album set")
        #expect(ReviewPresentation.noAlbumWord == "No album")
    }

    @Test func aResolvedRowCarriesItsDecision() async throws {
        let env = try ReviewEnv.make()
        let added = try await env.addGroup(title: "So U Know", versions: [("flac", 1_411), ("mp3", 320)], status: "resolved")
        let items = ReviewGroup.groups(from: try await AnalysisRepository(database: env.db).fetchResolvedReviews())
        let group = try #require(items.first { $0.key == added.key })
        #expect(ReviewModel.resolvedRow(group, decision: record(.keepSelected)).decision == "Kept selected")
        #expect(ReviewModel.resolvedRow(group, decision: nil).decision == "—")
    }
}
