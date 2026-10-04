import Testing
import Foundation
import GRDB
@testable import MLM

/// A3 Wave 2: the production initializer opens any database URL (a library file's
/// database) with WAL and the pre-migration backup, exactly like the legacy path.
@Suite("DatabaseManager library open (A3 Wave 2)", .serialized)
struct DatabaseManagerLibraryTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseManagerLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func opensALibraryFileDatabaseWithWALAndMigrations() throws {
        let root = try makeRoot()
        let package = try LibraryPackage.createEmpty(
            named: "Main Library", libraryId: "lib-a", in: root.appendingPathComponent("libraries"), now: Date())
        let manager = try DatabaseManager(
            databaseURL: LibraryPackage.databaseURL(in: package),
            backupsRoot: root.appendingPathComponent("backups"))

        let journalMode = try manager.pool.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        #expect(journalMode == "wal")
        let applied = try manager.pool.read { db in try DatabaseManager.buildMigrator().appliedIdentifiers(db) }
        #expect(applied == Set(DatabaseManager.buildMigrator().migrations))
        #expect(manager.playlistCoversDirectory == LibraryPackage.coversDirectory(in: package))
        #expect(manager.databasePath == LibraryPackage.databaseURL(in: package))
    }

    @Test func keepsForeignKeysDisabled() throws {
        let root = try makeRoot()
        let manager = try DatabaseManager(
            databaseURL: root.appendingPathComponent("x/music_library.db"),
            backupsRoot: root.appendingPathComponent("backups"))
        let enabled = try manager.pool.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
        #expect(enabled == 0)
    }

    @Test func runsThePreMigrationBackupIntoTheLibrarysFolder() throws {
        let root = try makeRoot()
        let package = try LibraryPackage.createEmpty(
            named: "Main Library", libraryId: "lib-a", in: root.appendingPathComponent("libraries"), now: Date())
        let dbURL = LibraryPackage.databaseURL(in: package)
        // Simulate an older build: one migration not yet applied, with data worth protecting.
        do {
            let queue = try DatabaseQueue(path: dbURL.path)
            let newest = try #require(DatabaseManager.buildMigrator().migrations.last)
            try queue.write { db in
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [newest])
            }
            try queue.close()
        }

        let backups = root.appendingPathComponent("backups")
        _ = try DatabaseManager(databaseURL: dbURL, backupsRoot: backups)

        let bundles = try FileManager.default.contentsOfDirectory(
            atPath: backups.appendingPathComponent("lib-a").path)
        #expect(bundles.count == 1)
        #expect(bundles.first?.hasPrefix("mlm-backup-") == true)
    }

    @Test func legacyLocationIsTheOldApplicationSupportPath() {
        #expect(DatabaseManager.legacyDatabaseURL.path.hasSuffix(
            "Library/Application Support/com.musiclibrary.app/music_library.db"))
    }
}
