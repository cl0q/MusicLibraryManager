import Foundation
import GRDB
import Testing
@testable import MLM

/// `v45_playlist_folders` (W3-PL, DEC-003). Temporary databases only; foreign keys stay off.
@Suite("PlaylistFoldersMigrationTests")
struct PlaylistFoldersMigrationTests {
    private static let v45 = "v45_playlist_folders"
    private static let previous = "v46_activity_operations"

    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = false
        return config
    }

    @Test func freshDatabaseHasTheFolderTableAndTheNewColumns() throws {
        let queue = try DatabaseManager.inMemory()
        let (folders, playlists, index) = try queue.read { db in
            (
                try db.columns(in: "playlist_folders").map(\.name),
                try db.columns(in: "playlists").map(\.name),
                try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'idx_playlists_folder_position'")
            )
        }
        #expect(folders == ["id", "name", "parent_id", "position", "date_created"])
        #expect(playlists.contains("folder_id"))
        #expect(playlists.contains("position"))
        #expect(playlists.contains("is_pinned"), "retired, never dropped (DEC-003)")
        #expect(index?.contains("folder_id") == true)
    }

    @Test func registeredOnceAfterTheLatestExistingMigration() throws {
        let migrations = DatabaseManager.buildMigrator().migrations
        #expect(migrations.filter { $0 == Self.v45 }.count == 1)
        let v41Index = try #require(migrations.firstIndex(of: "v41_remote_provider_identity"))
        let previousIndex = try #require(migrations.firstIndex(of: Self.previous))
        let v45Index = try #require(migrations.firstIndex(of: Self.v45))
        #expect(v41Index < v45Index)
        #expect(previousIndex < v45Index, "registered after v46 — existing migrations are never reordered")
    }

    /// The sidebar showed `is_pinned DESC, name` until now: that order is kept exactly.
    @Test func upgradeKeepsEveryPlaylistInTheOrderItWasShown() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.previous)
        try queue.write { db in
            for (name, pinned) in [("Warm-up", 0), ("Sets", 1), ("Ambient", 0), ("Zebra", 1), ("Bandcamp", 0), ("ambient lowercase", 0)] {
                try db.execute(sql: "INSERT INTO playlists (name, category, is_pinned) VALUES (?, 'regular', ?)",
                               arguments: [name, pinned])
            }
            try db.execute(sql: "INSERT INTO playlists (name, category, is_liked, is_pinned) VALUES ('Liked from SoundCloud', 'synced', 1, 0)")
        }
        let shownBefore = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM playlists ORDER BY is_pinned DESC, name")
        }
        let applied = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(BackupService.hasPendingMigrations(registered: Set(migrator.migrations), applied: applied),
                "the pre-migration backup sees v45 as pending")
        try migrator.migrate(queue)
        let (shownAfter, pinned, unplaced, folders) = try queue.read { db in
            (
                try PlaylistRepository.sidebarOrdered(db).map(\.name),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlists WHERE is_pinned = 1"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlists WHERE position IS NULL"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_folders")
            )
        }
        #expect(shownAfter == shownBefore)
        #expect(pinned == 2, "is_pinned is left untouched")
        #expect(unplaced == 0)
        #expect(folders == 0)
        // Positions really sort that way in SQL too (BINARY collation).
        let bySQL = try queue.read { db in try String.fetchAll(db, sql: "SELECT name FROM playlists ORDER BY position") }
        #expect(bySQL == shownBefore)
    }

    @Test func idempotentWhenColumnsAndPositionsAlreadyExist() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.previous)
        try queue.write { db in
            try db.execute(sql: "ALTER TABLE playlists ADD COLUMN position TEXT")
            try db.execute(sql: "INSERT INTO playlists (name, category, position) VALUES ('Kept', 'regular', 'a5')")
            try db.execute(sql: "INSERT INTO playlists (name, category) VALUES ('Added', 'regular')")
        }
        try migrator.migrate(queue)
        try migrator.migrate(queue)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT name, position FROM playlists ORDER BY position").map { ($0["name"] as String, $0["position"] as String?) }
        }
        #expect(rows.map(\.0) == ["Kept", "Added"], "a placed row keeps its place; the unplaced one goes after it")
        #expect(rows.first?.1 == "a5")
        #expect(rows.allSatisfy { $0.1 != nil })
    }

    @Test func foreignKeysStayDisabled() throws {
        let queue = try DatabaseManager.inMemory()
        let enabled = try queue.read { try Bool.fetchOne($0, sql: "PRAGMA foreign_keys") }
        #expect(enabled == false)
    }

    @Test func backfillKeysAreFrozenAndAscending() {
        let keys = DatabaseManager.v45BackfillKeys(count: 3, after: nil)
        #expect(keys == FractionalIndexer.evenlySpaced(count: 3))
        #expect(keys == keys.sorted())
        let after = DatabaseManager.v45BackfillKeys(count: 2, after: "a5")
        #expect(after.allSatisfy { $0 > "a5" })
        #expect(after == after.sorted())
    }
}
