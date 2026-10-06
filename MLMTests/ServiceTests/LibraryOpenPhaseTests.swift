import Testing
import Foundation
import GRDB
@testable import MLM

/// W3-LAUNCH: the phase hook of the open path (`Backing up before update…`,
/// `Updating the library… 3 of 5`). Reporting must not change what is migrated or backed up.
/// Temporary databases and a temporary backups root only.
@Suite("Library open phases (W3-LAUNCH)")
struct LibraryOpenPhaseTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [LibraryOpenPhase] = []
        func record(_ phase: LibraryOpenPhase) { lock.withLock { items.append(phase) } }
        var phases: [LibraryOpenPhase] { lock.withLock { items } }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryOpenPhaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func smallMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for index in 1...5 {
            migrator.registerMigration("m\(index)") { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS t\(index) (id INTEGER PRIMARY KEY)")
            }
        }
        return migrator
    }

    @Test func pendingMigrationsAreCountedOneByOne() throws {
        let queue = try DatabaseQueue()
        let migrator = smallMigrator()
        try migrator.migrate(queue, upTo: "m2")
        let recorder = Recorder()
        try DatabaseMigrationSteps.migrate(migrator, queue, progress: { recorder.record($0) })
        #expect(recorder.phases == [
            .updating(step: 1, total: 3), .updating(step: 2, total: 3), .updating(step: 3, total: 3),
        ])
        #expect(try queue.read { try migrator.appliedIdentifiers($0) } == ["m1", "m2", "m3", "m4", "m5"])
    }

    @Test func aGapRunsAsOneBlockLikeBefore() throws {
        let queue = try DatabaseQueue()
        let migrator = smallMigrator()
        try migrator.migrate(queue)
        try queue.write { try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'm2'") }
        let recorder = Recorder()
        try DatabaseMigrationSteps.migrate(migrator, queue, progress: { recorder.record($0) })
        #expect(recorder.phases == [.updating(step: nil, total: 1)])
        #expect(try queue.read { try migrator.appliedIdentifiers($0) }.count == 5)
    }

    @Test func aNewDatabaseOrNothingPendingReportsNothing() throws {
        let migrator = smallMigrator()
        let fresh = try DatabaseQueue()
        let recorder = Recorder()
        try DatabaseMigrationSteps.migrate(migrator, fresh, progress: { recorder.record($0) })
        try DatabaseMigrationSteps.migrate(migrator, fresh, progress: { recorder.record($0) })
        #expect(recorder.phases.isEmpty)
        #expect(try fresh.read { try migrator.appliedIdentifiers($0) }.count == 5)
    }

    /// The real open path: an older library is backed up, then updated, and says so.
    @Test func databaseManagerReportsBackupThenEachUpdate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("music_library.db")
        let backups = root.appendingPathComponent("backups")
        let migrator = DatabaseManager.buildMigrator()
        let ids = migrator.migrations
        try #require(ids.count >= 3)
        do {
            var config = Configuration()
            config.foreignKeysEnabled = false
            let pool = try DatabasePool(path: database.path, configuration: config)
            try migrator.migrate(pool, upTo: ids[ids.count - 3])
            try pool.write { db in
                try db.execute(sql: "INSERT OR REPLACE INTO app_config (key, value) VALUES ('library_id', 'lib-phase')")
            }
            try pool.close()
        }

        let recorder = Recorder()
        let manager = try DatabaseManager(databaseURL: database, backupsRoot: backups, progress: { recorder.record($0) })
        let phases = recorder.phases
        try #require(phases.count == 3, "\(phases)")
        guard case .backingUp(let bytes?) = phases[0] else {
            Issue.record("expected backingUp with a size, got \(phases[0])")
            return
        }
        #expect(bytes > 0)
        #expect(Array(phases.dropFirst()) == [.updating(step: 1, total: 2), .updating(step: 2, total: 2)])
        #expect(try manager.pool.read { try migrator.appliedIdentifiers($0) } == Set(ids))
        let bundles = try FileManager.default.contentsOfDirectory(atPath: backups.appendingPathComponent("lib-phase").path)
        #expect(bundles.contains { $0.hasPrefix("mlm-backup-") })
        try manager.pool.close()
    }

    @Test func phaseWords() {
        #expect(LibraryOpenPhase.checking.line == "Checking the library file…")
        #expect(LibraryOpenPhase.reading.line == "Reading the library…")
        #expect(LibraryOpenPhase.backingUp(bytes: nil).line == "Backing up before update…")
        #expect(LibraryOpenPhase.updating(step: 3, total: 5).line == "Updating the library…")
        #expect(LibraryOpenPhase.updating(step: 3, total: 5).count == "3 of 5")
        #expect(LibraryOpenPhase.updating(step: nil, total: 5).count == nil)
        #expect(LibraryOpenPhase.finishingSetup.line == "Finishing library file setup…")
        #expect(LibraryOpenPhase.finishingSetup.caption?.hasPrefix("The setup was interrupted last time.") == true)
        #expect(LibraryOpenPhase.backingUp(bytes: nil).isWriting && !LibraryOpenPhase.reading.isWriting)
    }
}
