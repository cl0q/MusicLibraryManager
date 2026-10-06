import Foundation
import GRDB
import Testing
@testable import MLM

/// `v54_review_hidden` (W3-REV fixes). Temporary databases only; foreign keys off.
@Suite("ReviewHiddenMigrationTests")
struct ReviewHiddenMigrationTests {
    private static let v54 = "v54_review_hidden"

    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = false
        return config
    }

    private func seed(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            for index in 1...4 {
                try db.execute(sql: """
                    INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path, is_duplicate, search_text)
                    VALUES ('Overmono', 'Overmono', 'Good Lies', 'So U Kno \(index)', 'mp3', '/\(index).mp3', 'A/\(index).mp3', ?, 'overmono so u kno')
                    """, arguments: [index >= 2 ? 1 : 0])
            }
        }
    }

    @Test func oldDuplicateFlagsStayListedAfterTheMigration() async throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: "v48_review_decisions")
        try seed(queue)
        try migrator.migrate(queue)
        let rows = try await TrackRepository(database: queue).fetchTracks(scope: .all)
        #expect(rows.count == 4)
        let summary = try await TrackScopeQueries(database: queue).scopeSummary()
        #expect(summary.counts.all == 4)
        let hidden = try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks WHERE hidden_by_review = 1") }
        #expect(hidden == 0, "no backfill")
    }

    @Test func idempotentAndKindColumnWithCompositeKey() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: "v48_review_decisions")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO review_decisions (group_key, kind, decision, consequences_json, decided_at)
                VALUES ('conflict:1:2', 'conflict', 'merge', '{}', '2026-10-01T10:00:00Z')
                """)
            try db.execute(sql: "INSERT INTO review_decided_pairs (track_a, track_b, decision_id) VALUES (1, 2, 1)")
            // The column already exists (a partially applied earlier run).
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN hidden_by_review INTEGER NOT NULL DEFAULT 0")
        }
        try migrator.migrate(queue)
        let (kind, columns) = try queue.read { db in
            (try String.fetchOne(db, sql: "SELECT kind FROM review_decided_pairs WHERE track_a = 1"),
             try db.columns(in: "review_decided_pairs").map(\.name))
        }
        #expect(kind == "conflict", "the kind of the owning decision is carried over")
        #expect(columns.contains("kind"))
        try queue.write { db in
            try db.execute(sql: "INSERT INTO review_decided_pairs (track_a, track_b, decision_id, kind) VALUES (1, 2, 2, 'duplicate')")
        }
        let count = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM review_decided_pairs") }
        #expect(count == 2, "uniqueness is per kind")
        let indexes = try queue.read { try $0.indexes(on: "tracks").map(\.name) }
        #expect(indexes.contains("idx_tracks_hidden_by_review"))
    }

    @Test @MainActor func aPreV48RowWithASnapshotCanBeRestored() throws {
        var details = ReviewDetails(groupKey: "duplicate:1:2", tracks: [])
        details.resolutionSnapshot = ReviewResolutionSnapshot(action: "keep_recommended", keptTrackIds: [1], unkeptTrackIds: [2])
        let item = ReviewItem(id: 1, actionType: "fingerprint_dedup", groupKey: "duplicate:1:2", trackId: 1, relatedTrackId: 2,
                              details: try details.encodedJSON(), autoAction: nil, status: "resolved")
        let row = ReviewModel.resolvedRow(ReviewGroup(key: "duplicate:1:2", items: [item]), decision: nil)
        #expect(row.canRestore)
        #expect(row.outcome == "Decided in an earlier version of MLM")
        let bare = ReviewItem(id: 2, actionType: "fingerprint_dedup", groupKey: "duplicate:3:4", trackId: 3, relatedTrackId: 4,
                              details: "{}", autoAction: nil, status: "resolved")
        #expect(!ReviewModel.resolvedRow(ReviewGroup(key: "duplicate:3:4", items: [bare]), decision: nil).canRestore)
    }

    @Test func registeredOnce() {
        #expect(DatabaseManager.buildMigrator().migrations.filter { $0 == Self.v54 }.count == 1)
    }
}
