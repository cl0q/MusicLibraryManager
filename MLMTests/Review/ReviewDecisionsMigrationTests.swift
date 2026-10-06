import Foundation
import GRDB
import Testing
@testable import MLM

/// `v48_review_decisions` (W3-REV, IMP-051). Temporary databases only; foreign keys off.
@Suite("ReviewDecisionsMigrationTests")
struct ReviewDecisionsMigrationTests {
    private static let v48 = "v48_review_decisions"
    private static let previous = "v47_sync_profile_results"

    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = false
        return config
    }

    @Test func freshDatabaseHasBothTablesAndTheIndex() throws {
        let queue = try DatabaseManager.inMemory()
        let (decisions, pairs, indexes) = try queue.read { db in
            (try db.columns(in: "review_decisions").map(\.name),
             try db.columns(in: "review_decided_pairs").map(\.name),
             try db.indexes(on: "review_decided_pairs").map(\.name))
        }
        #expect(decisions == ["id", "group_key", "kind", "decision", "kept_track_id", "unkept_mode",
                              "consequences_json", "decided_at"])
        #expect(pairs == ["track_a", "track_b", "decision_id"])
        #expect(indexes.contains("idx_review_decided_pairs_decision"))
        let fk = try queue.read { db in try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") }
        #expect(fk == false, "foreign keys stay disabled")
    }

    @Test func registeredOnceAfterTheLatestExistingMigration() throws {
        let migrations = DatabaseManager.buildMigrator().migrations
        #expect(migrations.filter { $0 == Self.v48 }.count == 1)
        let previousIndex = try #require(migrations.firstIndex(of: Self.previous))
        let index = try #require(migrations.firstIndex(of: Self.v48))
        #expect(previousIndex < index)
    }

    @Test func upgradeKeepsReviewRowsAndSeesTheMigrationAsPending() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.previous)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO review_queue (action_type, group_key, track_id, related_track_id, details, status)
                VALUES ('fingerprint_dedup', 'duplicate:1:2', 1, 2, '{}', 'resolved')
            """)
        }
        let applied = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(BackupService.hasPendingMigrations(registered: Set(migrator.migrations), applied: applied),
                "the pre-migration backup sees v48 as pending")
        try migrator.migrate(queue)
        let (rows, decisions) = try queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_queue"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_decisions"))
        }
        #expect(rows == 1)
        #expect(decisions == 0, "no backfill: earlier decisions recorded no consequences")
    }

    @Test func idempotentWhenTheTablesAlreadyExist() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.previous)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE review_decisions (id INTEGER PRIMARY KEY AUTOINCREMENT, group_key TEXT NOT NULL,
                    kind TEXT NOT NULL, decision TEXT NOT NULL, kept_track_id INTEGER, unkept_mode TEXT,
                    consequences_json TEXT NOT NULL, decided_at TEXT NOT NULL)
            """)
            try db.execute(sql: """
                INSERT INTO review_decisions (group_key, kind, decision, consequences_json, decided_at)
                VALUES ('duplicate:1:2', 'duplicate', 'keep_all', '{}', '2026-10-01T10:00:00Z')
            """)
        }
        try migrator.migrate(queue)
        let kept = try queue.read { db in try String.fetchOne(db, sql: "SELECT group_key FROM review_decisions") }
        #expect(kept == "duplicate:1:2")
        #expect(try queue.read { db in try db.tableExists("review_decided_pairs") })
    }
}
