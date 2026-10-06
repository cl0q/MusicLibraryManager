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

    /// S7: `DatabaseManager` marks a database that can't be read as the opening step.
    @Test func anUnreadableDatabaseIsTheOpeningStep() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("music_library.db")
        try Data(repeating: 0x5A, count: 8_192).write(to: database)
        do {
            _ = try DatabaseManager(databaseURL: database, backupsRoot: root.appendingPathComponent("backups"))
            Issue.record("a garbage file must not open")
        } catch let error as LibraryOpenError {
            #expect(error.stage == .opening)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path),
                "nothing was backed up from it")
    }

    /// A migration that fails in the middle: the stepped path stops at the same place, with the
    /// same applied set and the error surfaced, as `migrate()` does.
    @Test func aMigrationFailingMidStepLeavesTheSameStateAsMigrate() throws {
        struct Boom: Error {}
        func migrator() -> DatabaseMigrator {
            var migrator = DatabaseMigrator()
            for index in 1...5 {
                migrator.registerMigration("m\(index)") { db in
                    if index == 4 { throw Boom() }
                    try db.execute(sql: "CREATE TABLE IF NOT EXISTS t\(index) (id INTEGER PRIMARY KEY)")
                }
            }
            return migrator
        }
        let plain = try DatabaseQueue()
        let stepped = try DatabaseQueue()
        try migrator().migrate(plain, upTo: "m2")
        try migrator().migrate(stepped, upTo: "m2")
        #expect(throws: Boom.self) { try migrator().migrate(plain) }
        let recorder = Recorder()
        #expect(throws: Boom.self) {
            try DatabaseMigrationSteps.migrate(migrator(), stepped, progress: { recorder.record($0) })
        }
        let appliedPlain = try plain.read { try migrator().appliedIdentifiers($0) }
        let appliedStepped = try stepped.read { try migrator().appliedIdentifiers($0) }
        #expect(appliedPlain == ["m1", "m2", "m3"])
        #expect(appliedStepped == appliedPlain)
        #expect(recorder.phases == [.updating(step: 1, total: 3), .updating(step: 2, total: 3)])
    }

    /// The real migrator: stepped and plain migration leave identical schemas — for an older
    /// database (stepping) and for one with a gap (one block, like before).
    @Test func steppedAndPlainAreEquivalentWithTheRealMigrator() throws {
        let ids = DatabaseManager.buildMigrator().migrations
        try #require(ids.count > 6)

        func schema(_ queue: DatabaseQueue) -> [String] {
            do {
                return try queue.read { db in
                    try Row.fetchAll(db, sql: "SELECT type, name, sql FROM sqlite_master ORDER BY type, name")
                        .map { row in "\(row["type"] as String? ?? "") \(row["name"] as String? ?? "") \(row["sql"] as String? ?? "")" }
                        // Some existing migrations bake "now" into column defaults; compare the shape.
                        .map { $0.replacingOccurrences(of: #"'\d{4}-\d{2}-\d{2} [0-9:.]+'"#, with: "'<now>'", options: .regularExpression) }
                }
            } catch {
                Issue.record("schema unreadable: \(error)")
                return []
            }
        }
        func outcome(_ queue: DatabaseQueue, stepped: Bool) -> String {
            do {
                if stepped {
                    try DatabaseMigrationSteps.migrate(DatabaseManager.buildMigrator(), queue, progress: { _ in })
                } else {
                    try DatabaseManager.buildMigrator().migrate(queue)
                }
                return "ok"
            } catch {
                return "\(type(of: error))"
            }
        }
        func prepared(gap: Bool) throws -> DatabaseQueue {
            var config = Configuration()
            config.foreignKeysEnabled = false
            let queue = try DatabaseQueue(configuration: config)
            if gap {
                try DatabaseManager.buildMigrator().migrate(queue)
                try queue.write { db in
                    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [ids[ids.count / 2]])
                }
            } else {
                try DatabaseManager.buildMigrator().migrate(queue, upTo: ids[ids.count - 5])
            }
            return queue
        }

        for gap in [false, true] {
            let plain = try prepared(gap: gap)
            let stepped = try prepared(gap: gap)
            #expect(outcome(plain, stepped: false) == outcome(stepped, stepped: true), "gap: \(gap)")
            let a = schema(plain), b = schema(stepped)
            #expect(a == b, "gap: \(gap) — only plain: \(Set(a).subtracting(b)) — only stepped: \(Set(b).subtracting(a))")
            #expect(try plain.read { try DatabaseManager.buildMigrator().appliedIdentifiers($0) }
                    == stepped.read { try DatabaseManager.buildMigrator().appliedIdentifiers($0) })
        }
    }
}
