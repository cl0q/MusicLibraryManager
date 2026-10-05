import Foundation
import GRDB
import Testing
@testable import MLM

/// `v42_track_availability` (W2-A): persisted file presence. Temporary databases only.
@Suite("TrackAvailabilityMigrationTests")
struct TrackAvailabilityMigrationTests {
    private static let v41 = "v41_remote_provider_identity"
    private static let v42 = "v42_track_availability"

    @Test func freshDatabaseHasTheColumnAndThePartialIndex() async throws {
        let db = try DatabaseManager.inMemory()
        let (columns, indexSQL) = try await db.read { db in
            (
                try db.columns(in: "tracks"),
                try String.fetchOne(
                    db, sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_tracks_file_missing_since'")
            )
        }
        let column = try #require(columns.first { $0.name == "file_missing_since" })
        #expect(column.type.uppercased() == "TEXT")
        #expect(!column.isNotNull)
        #expect(columns.filter { $0.name == "file_missing_since" }.count == 1)
        #expect(indexSQL?.contains("WHERE file_missing_since IS NOT NULL") == true)
    }

    @Test func registeredOnceAfterV41AndLast() throws {
        let migrations = DatabaseManager.buildMigrator().migrations
        #expect(migrations.filter { $0 == Self.v42 }.count == 1)
        let v41Index = try #require(migrations.firstIndex(of: Self.v41))
        let v42Index = try #require(migrations.firstIndex(of: Self.v42))
        #expect(v41Index < v42Index)
        #expect(migrations.last == Self.v42)
    }

    @Test func upgradeFromV41KeepsEveryRowAndFlagsNothingMissing() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.v41)
        let hadColumn = try queue.read { db in try db.columns(in: "tracks").contains { $0.name == "file_missing_since" } }
        #expect(!hadColumn)
        try queue.write { db in
            for index in 0..<50 {
                // Local rows (relative and absolute paths, some files surely absent), remote
                // rows, failed rows — none may come out flagged.
                let organized: String? = index % 3 == 0 ? nil : (index % 3 == 1 ? "A/\(index).m4a" : "/Volumes/Gone/\(index).m4a")
                try db.execute(sql: """
                    INSERT INTO tracks (artist, album_artist, album, title, format, original_path, organized_path,
                                        is_duplicate, download_status, duration)
                    VALUES ('Artist', 'Artist', 'Album', ?, 'm4a', ?, ?, 0, ?, 200)
                    """, arguments: ["T\(index)", "/orig/\(index).m4a", organized, index % 5 == 0 ? "failed" : nil])
            }
        }
        // Pending: the pre-migration backup hook sees v42 as pending.
        let applied = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(BackupService.hasPendingMigrations(registered: Set(migrator.migrations), applied: applied))

        try migrator.migrate(queue)
        let (total, flagged, local) = try queue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE file_missing_since IS NOT NULL"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE organized_path IS NOT NULL")
            )
        }
        #expect(total == 50)
        #expect(flagged == 0)
        #expect(local == 33)
        let after = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(after.contains(Self.v42))
        #expect(!BackupService.hasPendingMigrations(registered: Set(migrator.migrations), applied: after))
    }

    @Test func idempotentWhenTheColumnAlreadyExists() throws {
        // A shared database that already has the column (e.g. added by hand) must migrate.
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.v41)
        try queue.write { db in
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN file_missing_since TEXT")
        }
        try migrator.migrate(queue)
        try migrator.migrate(queue)  // re-running is a no-op
        let count = try queue.read { db in try db.columns(in: "tracks").filter { $0.name == "file_missing_since" }.count }
        #expect(count == 1)
    }

    @Test func foreignKeysStayDisabled() throws {
        let queue = try DatabaseManager.inMemory()
        let enabled = try queue.read { try Bool.fetchOne($0, sql: "PRAGMA foreign_keys") }
        #expect(enabled == false)
    }

    @Test func savingATrackNeverClobbersTheMissingFact() async throws {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        var track = Track(artist: "A", album: "B", title: "C", format: "m4a", originalPath: "/x.m4a")
        track.organizedPath = "A/C.m4a"
        let inserted = try await repo.insert(track)
        let id = try #require(inserted.id)
        #expect(try await repo.recordFileMissing(trackId: id))
        // A stale copy loaded before the flag was written is saved again (tag edit, …).
        var stale = inserted
        stale.title = "Renamed"
        try await repo.update(stale)
        let fetched = try #require(try await repo.fetchTrack(id: id))
        #expect(fetched.title == "Renamed")
        #expect(fetched.fileMissingSince != nil)
        #expect(fetched.availability() == .fileMissing)
    }

    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = false
        return config
    }
}
