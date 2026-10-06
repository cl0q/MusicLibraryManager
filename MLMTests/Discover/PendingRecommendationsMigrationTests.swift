import Foundation
import GRDB
import Testing
@testable import MLM

/// `v49_pending_recommendations` (W3-DISC-A, IMP-053). Temporary databases only; foreign keys off.
@Suite("PendingRecommendationsMigrationTests")
struct PendingRecommendationsMigrationTests {
    private static let v49 = "v49_pending_recommendations"
    private static let previous = "v48_review_decisions"

    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = false
        return config
    }

    @Test func freshDatabaseHasTheFlagAndTheTrashColumn() throws {
        let queue = try DatabaseManager.inMemory()
        let (tracks, log) = try queue.read { db in
            (try db.columns(in: "tracks").map(\.name), try db.columns(in: "track_discovery_log").map(\.name))
        }
        #expect(tracks.contains("is_pending_recommendation"))
        #expect(log.contains("trash_url"))
        #expect(try queue.read { try Bool.fetchOne($0, sql: "PRAGMA foreign_keys") } == false)
    }

    @Test func registeredOnceAfterV48() throws {
        let migrations = DatabaseManager.buildMigrator().migrations
        #expect(migrations.filter { $0 == Self.v49 }.count == 1)
        let previousIndex = try #require(migrations.firstIndex(of: Self.previous))
        let index = try #require(migrations.firstIndex(of: Self.v49))
        #expect(previousIndex < index)
    }

    private func insertTrack(_ db: Database, _ id: Int64) throws {
        try db.execute(sql: """
            INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, is_duplicate)
            VALUES (?, 'A', 'A', '', ?, 'm4a', ?, 0)
        """, arguments: [id, "T\(id)", "/o/\(id).m4a"])
    }

    @Test func upgradeBackfillsHeldTracksFromWaitingLogRowsOnly() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.previous)
        try queue.write { db in
            for id in 1...4 { try insertTrack(db, Int64(id)) }
            for (id, status) in [(2, "new"), (3, "approved"), (4, "new")] {
                try db.execute(sql: """
                    INSERT INTO track_discovery_log (discovered_track_id, seed_track_id, discovery_source, status)
                    VALUES (?, 1, 'soundcloud', ?)
                """, arguments: [id, status])
            }
        }
        let applied = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(BackupService.hasPendingMigrations(registered: Set(migrator.migrations), applied: applied),
                "the pre-migration backup sees v49 as pending")
        try migrator.migrate(queue)
        let held = try queue.read { try Int64.fetchAll($0, sql: "SELECT id FROM tracks WHERE is_pending_recommendation = 1 ORDER BY id") }
        #expect(held == [2, 4])
        let free = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks WHERE is_pending_recommendation = 0") }
        #expect(free == 2)
    }

    @Test func idempotentWhenTheColumnsAlreadyExist() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.previous)
        try queue.write { db in
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN is_pending_recommendation INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE track_discovery_log ADD COLUMN trash_url TEXT")
            try insertTrack(db, 1)
            try db.execute(sql: """
                INSERT INTO track_discovery_log (discovered_track_id, seed_track_id, discovery_source, status, trash_url)
                VALUES (1, NULL, 'lastfm', 'new', '/Trash/x')
            """)
        }
        try migrator.migrate(queue)
        let row = try queue.read {
            try Row.fetchOne($0, sql: """
                SELECT t.is_pending_recommendation AS f, l.trash_url AS u
                FROM tracks t JOIN track_discovery_log l ON l.discovered_track_id = t.id
            """)
        }
        #expect(row?["f"] == 1)
        #expect(row?["u"] == "/Trash/x")
    }
}
