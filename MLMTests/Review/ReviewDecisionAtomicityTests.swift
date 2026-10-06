import Foundation
import GRDB
import Testing
@testable import MLM

/// F5: pairs per kind, tag merges inside the decision, bulk apply is one transaction.
@Suite("ReviewDecisionAtomicityTests")
struct ReviewDecisionAtomicityTests {
    private typealias Repo = ReviewDecisionRepositoryTests

    private func proposal(ids: [Int64], type: String) -> ReviewItem {
        let key = DuplicateReviewGrouping.groupKey(for: ids)
        return ReviewItem(id: nil, actionType: type, groupKey: key, trackId: ids[0], relatedTrackId: ids[1],
                          details: (try? ReviewDetails(groupKey: key, tracks: ids.map { ReviewTrackSnapshot(id: $0, title: "t", artist: "a") }).encodedJSON()) ?? "{}",
                          autoAction: nil, status: "pending", createdAt: nil, resolvedAt: nil)
    }

    @Test func aMergedConflictCanLaterBeProposedAsADuplicate() async throws {
        let f = try Repo.makeFixture(members: 2, pending: false)
        try await f.queue.write { db in
            try db.execute(sql: """
                INSERT INTO review_queue (action_type, group_key, track_id, related_track_id, details, status)
                VALUES ('metadata_conflict', ?, ?, ?, '{}', 'pending')
                """, arguments: [f.groupKey, f.ids[0], f.ids[1]])
        }
        var request = Repo.request(f, action: .merge, kept: nil)
        request.kind = .conflict
        try await f.decisions.decide(request)
        #expect(try await f.decisions.decidedPairs(kind: .conflict).count == 1)
        #expect(try await f.decisions.decidedPairs(kind: .duplicate).isEmpty)
        let again = try await f.analysis.replacePendingScanReviewItems([proposal(ids: f.ids, type: "metadata_conflict")])
        #expect(again.conflicts == 0, "the conflict stays decided")
        let asDuplicate = try await f.analysis.replacePendingScanReviewItems([proposal(ids: f.ids, type: "fingerprint_dedup")])
        #expect(asDuplicate.duplicates == 1, "a merge says nothing about being duplicates")
    }

    @Test func aNewerDecisionsUndoNeverDeletesAnOlderDecisionsPairs() async throws {
        let f = try Repo.makeFixture(members: 2)
        let first = try await f.decisions.decide(Repo.request(f, action: .keepAll, kept: nil))
        // A second decision on the same pair (e.g. the group came back through an older record).
        try await f.queue.write { db in
            try db.execute(sql: "UPDATE review_queue SET status = 'pending'")
        }
        let second = try await f.decisions.decide(Repo.request(f, action: .keepAll, kept: nil))
        try await f.decisions.undo(decisionID: second.decisionID)
        #expect(try await f.decisions.decidedPairs().count == 1, "the first decision still covers the pair")
        _ = first
    }

    @Test func bulkWithOneBadGroupCommitsNothing() async throws {
        let queue = try DatabaseManager.inMemory()
        let decisions = ReviewDecisionRepository(database: queue)
        var requests: [ReviewDecisionRequest] = []
        var allIDs: [Int64] = []
        for title in ["Alpha", "Beta"] {
            let ids: [Int64] = try await queue.write { db in
                var ids: [Int64] = []
                for index in 0..<2 {
                    var track = Track(artist: "A", album: "B", title: title, format: "mp3", originalPath: "/\(title)\(index)")
                    try track.insert(db)
                    ids.append(track.id!)
                }
                let key = DuplicateReviewGrouping.groupKey(for: ids)
                try db.execute(sql: """
                    INSERT INTO review_queue (action_type, group_key, track_id, related_track_id, details, status)
                    VALUES ('fingerprint_dedup', ?, ?, ?, '{}', 'pending')
                    """, arguments: [key, ids[0], ids[1]])
                return ids
            }
            allIDs += ids
            // The second group names a kept version that isn't a member.
            requests.append(ReviewDecisionRequest(groupKey: DuplicateReviewGrouping.groupKey(for: ids), kind: .duplicate,
                                                  action: .keepRecommended, memberIDs: ids,
                                                  keptTrackID: title == "Alpha" ? ids[0] : 9_999, unkeptMode: .hidden))
        }
        await #expect(throws: ReviewDecisionError.invalidKeep) {
            try await decisions.decideAll(requests)
        }
        let (hidden, decided, pending) = try await queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE hidden_by_review = 1"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_decisions"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_queue WHERE status = 'pending'"))
        }
        #expect(hidden == 0)
        #expect(decided == 0)
        #expect(pending == 2, "the first group wasn't decided either")
        #expect(allIDs.count == 4)
    }

    @MainActor
    @Test func aBadBulkSaysNothingWasChangedAndLeavesEveryGroupPending() async throws {
        let env = try ReviewEnv.make()
        try await env.addGroup(title: "Alpha", versions: [("flac", 1411), ("mp3", 320)])
        try await env.addGroup(title: "Beta", versions: [("flac", 1411), ("mp3", 320)])
        await env.model.reload()
        let items = env.model.duplicates
        var plans = items.map { env.model.plan(keepRecommendedIn: $0) }
        plans[1].request.keptTrackID = 9_999
        let applied = await env.model.apply(plans, actionName: "Keep Recommended Versions", undo: env.undo)
        #expect(!applied)
        #expect(env.status.message?.text == "Couldn’t apply the decisions — nothing was changed")
        #expect(env.undo.stepCount == 0)
        #expect(env.model.duplicateCount == 2)
        let hidden = try await env.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks WHERE hidden_by_review = 1") }
        #expect(hidden == 0)
    }

    @MainActor
    @Test func aMergeChangesNoTagsWhenTheDecisionDoesNotHappen() async throws {
        let env = try ReviewEnv.make()
        let group = try await env.addGroup(title: "Tangerine", versions: [("flac", 1411), ("mp3", 320)],
                                           conflict: true, albums: ["A", "B"])
        await env.model.reload()
        let item = try #require(env.model.conflicts.first)
        env.model.useAll(from: group.ids[1], in: item)
        let plan = env.model.plan(mergeIn: item)
        // Decided elsewhere meanwhile.
        try await env.decisions.decide(ReviewDecisionRequest(groupKey: group.key, kind: .conflict, action: .keepBoth,
                                                            memberIDs: group.ids))
        let applied = await env.model.apply([plan], actionName: "Merge Tags", undo: env.undo)
        #expect(!applied)
        let albums = try await env.db.read { try String.fetchAll($0, sql: "SELECT album FROM tracks ORDER BY id") }
        #expect(albums == ["A", "B"], "no tag changed")
    }

    @MainActor
    @Test func theMergeUndoUsesTheSnapshotsTheTagEditReturned() async throws {
        let env = try ReviewEnv.make()
        let group = try await env.addGroup(title: "Tangerine", versions: [("flac", 1411), ("mp3", 320)],
                                           conflict: true, albums: ["A", "B"])
        await env.model.reload()
        let item = try #require(env.model.conflicts.first)
        env.model.useAll(from: group.ids[1], in: item)
        await env.model.apply([env.model.plan(mergeIn: item)], actionName: "Merge Tags", undo: env.undo)
        let record = try #require(try await env.decisions.decisions()[group.key])
        #expect(record.consequences.tags.map(\.trackId) == [group.ids[0]], "only the version that changed")
        #expect(record.consequences.tags.first?.old == .text("A"))
    }
}
