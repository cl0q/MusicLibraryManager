import Testing
import Foundation
import GRDB
@testable import MLM

/// W3-LAUNCH review S2: `Try Again` on a failed update must not push manual, scheduled or
/// pre-adoption backups out. Bundles of a protecting reason are pruned only against their own
/// reason; the pre-update backup is written once per session for the same applied migrations.
/// Temporary databases and backups roots only.
@Suite("Backup pruning of protected reasons (W3-LAUNCH review)")
struct BackupProtectedPruningTests {

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BackupProtectedPruningTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A migrated database carrying `library_id`.
    private func makeDatabase(in root: URL, id: String = "lib-p") throws -> (DatabaseQueue, URL) {
        let url = root.appendingPathComponent("music_library.db")
        let manager = try DatabaseManager(path: url)
        try manager.pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO app_config (key, value) VALUES ('library_id', ?)", arguments: [id])
        }
        try manager.pool.close()
        return (try DatabaseQueue(path: url.path), url)
    }

    private func reasons(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("mlm-backup-") }
            .compactMap { bundle -> String? in
                let data = try Data(contentsOf: bundle.appendingPathComponent("backup.json"))
                return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
            }
    }

    @Test func repeatedPreUpdateBackupsNeverPushOutOtherReasons() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (queue, url) = try makeDatabase(in: root)
        defer { try? queue.close() }
        let backups = root.appendingPathComponent("backups")
        var clock = Date(timeIntervalSince1970: 1_791_000_000)
        func bundle(_ reason: BackupReason) throws {
            clock = clock.addingTimeInterval(60)
            let now = clock
            _ = try BackupService.createBundle(database: queue, databasePath: url, coversDirectory: nil,
                                               reason: reason, backupsRoot: backups, now: { now })
        }

        try bundle(.preAdoption)
        try bundle(.manual)
        for _ in 0..<12 { try bundle(.preMigration) }
        var left = try reasons(in: backups.appendingPathComponent("lib-p"))
        #expect(left.filter { $0 == "preMigration" }.count == 10, "the newest 10 of their own reason")
        #expect(left.contains("preAdoption"))
        #expect(left.contains("manual"))

        // And the other way round: many manual backups never drop the protected ones.
        for _ in 0..<12 { try bundle(.manual) }
        left = try reasons(in: backups.appendingPathComponent("lib-p"))
        #expect(left.filter { $0 == "manual" }.count == 10)
        #expect(left.filter { $0 == "preMigration" }.count == 10)
        #expect(left.filter { $0 == "preAdoption" }.count == 1)
    }

    @Test func thePreUpdateBackupIsWrittenOncePerSessionForTheSameMigrations() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("music_library.db")
        var config = Configuration()
        config.foreignKeysEnabled = false
        let pool = try DatabasePool(path: url.path, configuration: config)
        defer { try? pool.close() }
        let ids = DatabaseManager.buildMigrator().migrations
        try DatabaseManager.buildMigrator().migrate(pool, upTo: ids[ids.count - 2])
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO app_config (key, value) VALUES ('library_id', 'lib-s')")
        }
        let backups = root.appendingPathComponent("backups")

        var reports = 0
        let first = try BackupService.performPreMigrationBackupIfNeeded(
            pool: pool, databasePath: url, backupsRoot: backups, willBackUp: { reports += 1 })
        let second = try BackupService.performPreMigrationBackupIfNeeded(
            pool: pool, databasePath: url, backupsRoot: backups, willBackUp: { reports += 1 })
        #expect(first != nil)
        #expect(second == first)
        #expect(reports == 1)
        #expect(try reasons(in: backups.appendingPathComponent("lib-s")) == ["preMigration"])

        // One more migration applied: a different state, a new backup.
        try DatabaseManager.buildMigrator().migrate(pool, upTo: ids[ids.count - 2])
        try pool.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [ids[ids.count - 2]])
        }
        let third = try BackupService.performPreMigrationBackupIfNeeded(pool: pool, databasePath: url, backupsRoot: backups)
        #expect(third != nil && third != first)
    }
}
