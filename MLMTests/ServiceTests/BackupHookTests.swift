import Testing
import Foundation
import GRDB
@testable import MLM

/// Wave 2 tests for the synchronous pre-migration backup hook and the
/// `backup_destination` config accessors.
///
/// The hook is tested directly — never through `DatabaseManager.init()`, which targets
/// the live install. Every hook call pins its destination to a temp dir (override or config).
@Suite("BackupService hooks (Wave 2)", .serialized)
struct BackupHookTests {

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let dbPath: URL
        let manager: DatabaseManager

        init() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("BackupHookTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            self.root = root
            self.dbPath = root.appendingPathComponent("music_library.db")
            self.manager = try DatabaseManager(path: dbPath)
            try await manager.pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        /// Fabricate a pending migration by un-applying the newest registered one.
        func unapplyNewestMigration() async throws -> String {
            let newest = try #require(DatabaseManager.buildMigrator().migrations.last)
            try await manager.pool.write { db in
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [newest])
            }
            return newest
        }

        func readManifest(in bundle: URL) throws -> [String: Any] {
            let data = try Data(contentsOf: bundle.appendingPathComponent("backup.json"))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    // MARK: - Pending detection

    @Test func hasPendingMigrationsDetectsSetDifference() {
        #expect(!BackupService.hasPendingMigrations(registered: ["v1", "v2"], applied: ["v1", "v2"]))
        #expect(BackupService.hasPendingMigrations(registered: ["v1", "v2", "v3"], applied: ["v1", "v2"]))
        #expect(BackupService.hasPendingMigrations(registered: ["v1"], applied: []))
        // Applied-but-unregistered (DB from a newer build) is not "pending".
        #expect(!BackupService.hasPendingMigrations(registered: ["v1"], applied: ["v1", "v2"]))
    }

    // MARK: - Pre-migration hook

    @Test func performPreMigrationBackupSkipsWhenNothingPending() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        let destination = fixture.root.appendingPathComponent("backups")
        let result = try BackupService.performPreMigrationBackupIfNeeded(
            pool: fixture.manager.pool,
            databasePath: fixture.dbPath,
            destinationOverride: destination
        )

        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// Regression: on first launch the DB is empty, every migration is "pending", and
    /// snapshotting it used to fail on the missing `tracks` table — aborting startup.
    @Test func performPreMigrationBackupSkipsFreshDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupHookTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbPath = root.appendingPathComponent("music_library.db")
        let pool = try DatabasePool(path: dbPath.path)
        let destination = root.appendingPathComponent("backups")

        let result = try BackupService.performPreMigrationBackupIfNeeded(
            pool: pool,
            databasePath: dbPath,
            destinationOverride: destination
        )

        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func performPreMigrationBackupCreatesBundleWhenPending() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        let unapplied = try await fixture.unapplyNewestMigration()
        let covers = fixture.root.appendingPathComponent("playlist-covers")
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        try Data("PNG".utf8).write(to: covers.appendingPathComponent("cover1.png"))
        let destination = fixture.root.appendingPathComponent("backups")

        let bundle = try #require(try BackupService.performPreMigrationBackupIfNeeded(
            pool: fixture.manager.pool,
            databasePath: fixture.dbPath,
            coversDirectory: covers,
            destinationOverride: destination
        ))

        #expect(bundle.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL)
        #expect(bundle.lastPathComponent.hasPrefix("mlm-backup-"))
        #expect(FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("playlist-covers/cover1.png").path
        ))

        let manifest = try fixture.readManifest(in: bundle)
        #expect(manifest["reason"] as? String == BackupReason.preMigration.rawValue)
        #expect(manifest["source_database_path"] as? String == fixture.dbPath.path)

        // The snapshot captures the pre-migration state: the un-applied migration is absent.
        let snapshot = try DatabaseQueue(path: bundle.appendingPathComponent("music_library.db").path)
        defer { try? snapshot.close() }
        let applied = try await snapshot.read { db in
            try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(!applied.contains(unapplied))
        #expect(!applied.isEmpty)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            .filter { $0.hasPrefix(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test func performPreMigrationBackupUsesConfiguredDestination() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        _ = try await fixture.unapplyNewestMigration()
        let configured = fixture.root.appendingPathComponent("configured-backups")
        try await ConfigRepository(database: fixture.manager.pool).setBackupDestination(configured.path)

        let bundle = try #require(try BackupService.performPreMigrationBackupIfNeeded(
            pool: fixture.manager.pool,
            databasePath: fixture.dbPath
        ))

        #expect(bundle.deletingLastPathComponent().standardizedFileURL == configured.standardizedFileURL)
    }

    @Test func performPreMigrationBackupThrowsWhenDestinationNotWritable() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanup() }

        _ = try await fixture.unapplyNewestMigration()
        let readOnly = fixture.root.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path)
        }

        #expect(throws: BackupError.destinationNotWritable) {
            try BackupService.performPreMigrationBackupIfNeeded(
                pool: fixture.manager.pool,
                databasePath: fixture.dbPath,
                destinationOverride: readOnly.appendingPathComponent("backups")
            )
        }
    }

    // MARK: - Config accessors

    @Test func backupDestinationRoundTrip() async throws {
        let repo = ConfigRepository(database: try DatabaseManager.inMemory())

        #expect(try await repo.getBackupDestination() == nil)
        try await repo.setBackupDestination("/Volumes/Backup/mlm")
        #expect(try await repo.getBackupDestination() == "/Volumes/Backup/mlm")
    }
}
