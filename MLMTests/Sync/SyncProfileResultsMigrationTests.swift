import Foundation
import GRDB
import Testing
@testable import MLM

/// `v47_sync_profile_results` (W3-SYNC, PP-SYNC-02). Temporary databases only; foreign keys off.
@Suite("SyncProfileResultsMigrationTests")
struct SyncProfileResultsMigrationTests {
    private static let v47 = "v47_sync_profile_results"
    private static let previous = "v45_playlist_folders"

    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = false
        return config
    }

    private static let columns = [
        "profile_id", "started_at", "ended_at", "outcome", "planned_count", "copied_count", "removed_count",
        "failed_count", "skipped_count", "failures", "skipped", "plan_summary", "failure_cause",
        "operation_id", "last_interrupted_at", "last_connected_at",
    ]

    @Test func freshDatabaseHasTheTable() throws {
        let queue = try DatabaseManager.inMemory()
        let columns = try queue.read { db in try db.columns(in: "sync_profile_results").map(\.name) }
        #expect(columns == Self.columns)
        let fk = try queue.read { db in try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") }
        #expect(fk == false, "foreign keys stay disabled")
    }

    @Test func registeredOnceAfterTheLatestExistingMigration() throws {
        let migrations = DatabaseManager.buildMigrator().migrations
        #expect(migrations.filter { $0 == Self.v47 }.count == 1)
        #expect(migrations.last == Self.v47)
        let previousIndex = try #require(migrations.firstIndex(of: Self.previous))
        let index = try #require(migrations.firstIndex(of: Self.v47))
        #expect(previousIndex < index)
    }

    @Test func upgradeKeepsProfilesAndSyncStateAndSeesTheMigrationAsPending() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.previous)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix) VALUES ('iPod', '/Volumes/IPOD', '')")
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (1, 7, 'x', 10, '2026-10-01 10:00:00')
            """)
        }
        let applied = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(BackupService.hasPendingMigrations(registered: Set(migrator.migrations), applied: applied),
                "the pre-migration backup sees v47 as pending")
        try migrator.migrate(queue)
        let (profiles, states, results) = try queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_profiles"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_state"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_profile_results"))
        }
        #expect(profiles == 1)
        #expect(states == 1)
        #expect(results == 0, "no backfill: earlier results lived only in memory")
    }

    @Test func idempotentWhenTheTableAlreadyExists() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.previous)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE sync_profile_results (
                    profile_id INTEGER PRIMARY KEY NOT NULL, started_at TEXT, ended_at TEXT,
                    outcome TEXT NOT NULL DEFAULT 'none', planned_count INTEGER NOT NULL DEFAULT 0,
                    copied_count INTEGER NOT NULL DEFAULT 0, removed_count INTEGER NOT NULL DEFAULT 0,
                    failed_count INTEGER NOT NULL DEFAULT 0, skipped_count INTEGER NOT NULL DEFAULT 0,
                    failures TEXT, skipped TEXT, plan_summary TEXT, failure_cause TEXT, operation_id TEXT,
                    last_interrupted_at TEXT, last_connected_at TEXT)
            """)
            try db.execute(sql: "INSERT INTO sync_profile_results (profile_id, outcome) VALUES (3, 'completed')")
        }
        try migrator.migrate(queue)
        let kept = try queue.read { db in try String.fetchOne(db, sql: "SELECT outcome FROM sync_profile_results WHERE profile_id = 3") }
        #expect(kept == "completed")
    }
}

@Suite("SyncProfileResultRepositoryTests")
struct SyncProfileResultRepositoryTests {
    private func make() throws -> (DatabaseQueue, SyncRepository, SyncProfileResultRepository) {
        let db = try DatabaseManager.inMemory()
        return (db, SyncRepository(database: db), SyncProfileResultRepository(database: db))
    }

    private let failure = SyncResultFailure(trackID: 5, title: "So U Kno", artist: "Overmono",
                                            reason: "The device is full", devicePath: "/Volumes/IPOD/Overmono/So U Kno.m4a")

    @Test func resultsArePerProfileAndPersistAcrossReads() async throws {
        let (_, sync, results) = try make()
        let a = try await sync.create(name: "A", outputFolder: "/tmp/a").id!
        let b = try await sync.create(name: "B", outputFolder: "/tmp/b").id!
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = SyncPlanSummary(add: 3, remove: 1, skip: 2, addBytes: 300, freeBytes: 9_000, cleanUp: true, totalTracks: 5)
        try await results.begin(profileID: a, startedAt: start, plannedCount: 3, plan: plan, operationID: UUID())
        try await results.finish(profileID: a, outcome: .completed, endedAt: start.addingTimeInterval(60),
                                 copiedCount: 2, removedCount: 1, failures: [failure],
                                 skipped: [SyncResultSkip(trackID: 9, title: "Is U", artist: "Overmono", reason: .notDownloaded)])

        let all = try await results.fetchAll()
        #expect(all[b] == nil, "profile B has no result of A")
        let stored = try #require(all[a])
        #expect(stored.outcome == .completed)
        #expect(stored.copiedCount == 2)
        #expect(stored.failures == [failure])
        #expect(stored.skipped.map(\.reason) == [.notDownloaded])
        #expect(stored.plan == plan)
        #expect(stored.endedAt == start.addingTimeInterval(60))
    }

    @Test func interruptionKeepsTheCopiedCountAndResumeRunsAgain() async throws {
        let (_, sync, results) = try make()
        let a = try await sync.create(name: "A", outputFolder: "/tmp/a").id!
        try await results.begin(profileID: a, startedAt: Date(), plannedCount: 214, plan: nil, operationID: nil)
        try await results.recordProgress(profileID: a, copiedCount: 40)
        try await results.recordInterruption(profileID: a, copiedCount: 86, at: Date())
        var stored = try #require(try await results.fetch(profileID: a))
        #expect(stored.outcome == .interrupted)
        #expect(stored.copiedCount == 86)
        #expect(stored.plannedCount == 214)
        #expect(stored.lastInterruptedAt != nil)
        try await results.recordResumed(profileID: a)
        stored = try #require(try await results.fetch(profileID: a))
        #expect(stored.outcome == .running)
    }

    @Test func retryUpdatesOnlyThatProfile() async throws {
        let (_, sync, results) = try make()
        let a = try await sync.create(name: "A", outputFolder: "/tmp/a").id!
        let b = try await sync.create(name: "B", outputFolder: "/tmp/b").id!
        for id in [a, b] {
            try await results.begin(profileID: id, startedAt: Date(), plannedCount: 1, plan: nil, operationID: nil)
            try await results.finish(profileID: id, outcome: .completed, endedAt: Date(), copiedCount: 0,
                                     removedCount: 0, failures: [failure], skipped: [])
        }
        try await results.applyRetry(profileID: a, copiedTrackIDs: [5], stillFailing: [])
        let all = try await results.fetchAll()
        #expect(all[a]?.failures.isEmpty == true)
        #expect(all[a]?.copiedCount == 1)
        #expect(all[b]?.failures == [failure], "B keeps its own failures")
    }

    @Test func aRunLeftRunningAtLaunchBecomesInterrupted() async throws {
        let (_, sync, results) = try make()
        let a = try await sync.create(name: "A", outputFolder: "/tmp/a").id!
        let b = try await sync.create(name: "B", outputFolder: "/tmp/b").id!
        try await results.begin(profileID: a, startedAt: Date(), plannedCount: 9, plan: nil, operationID: nil)
        try await results.recordProgress(profileID: a, copiedCount: 4)
        try await results.begin(profileID: b, startedAt: Date(), plannedCount: 1, plan: nil, operationID: nil)
        try await results.finish(profileID: b, outcome: .completed, endedAt: Date(), copiedCount: 1,
                                 removedCount: 0, failures: [], skipped: [])
        try await results.markStaleRunsInterrupted()
        let all = try await results.fetchAll()
        #expect(all[a]?.outcome == .interrupted)
        #expect(all[a]?.copiedCount == 4, "what arrived stays counted")
        #expect(all[a]?.lastInterruptedAt != nil)
        #expect(all[b]?.outcome == .completed, "finished runs are untouched")
    }

    @Test func anUnreadableElementIsDroppedAndTheRestStays() async throws {
        let (db, sync, results) = try make()
        let a = try await sync.create(name: "A", outputFolder: "/tmp/a").id!
        try await results.begin(profileID: a, startedAt: Date(), plannedCount: 2, plan: nil, operationID: nil)
        try await results.finish(profileID: a, outcome: .completed, endedAt: Date(), copiedCount: 0,
                                 removedCount: 0, failures: [failure], skipped: [])
        // A newer version wrote a failure this one can't read, between two it can.
        let good = try String(decoding: JSONEncoder().encode(failure), as: UTF8.self)
        try await db.write { db in
            try db.execute(sql: "UPDATE sync_profile_results SET failures = ? WHERE profile_id = ?",
                           arguments: ["[\(good),{\"unknown\":true},\(good)]", a])
        }
        #expect(try await results.fetch(profileID: a)?.failures == [failure, failure])
    }

    @Test func connectionDateSurvivesANewRun() async throws {
        let (_, sync, results) = try make()
        let a = try await sync.create(name: "A", outputFolder: "/tmp/a").id!
        let seen = Date(timeIntervalSince1970: 1_790_000_000)
        try await results.recordConnected(profileID: a, at: seen)
        try await results.begin(profileID: a, startedAt: Date(), plannedCount: 1, plan: nil, operationID: nil)
        let stored = try #require(try await results.fetch(profileID: a))
        #expect(stored.lastConnectedAt == seen)
        #expect(stored.outcome == .running)
    }

    @Test func deletingAProfileCascadesItsResultOnly() async throws {
        let (db, sync, results) = try make()
        let a = try await sync.create(name: "A", outputFolder: "/tmp/a").id!
        let b = try await sync.create(name: "B", outputFolder: "/tmp/b").id!
        for id in [a, b] {
            try await results.begin(profileID: id, startedAt: Date(), plannedCount: 1, plan: nil, operationID: nil)
        }
        try await sync.delete(id: a)
        let remaining = try await db.read { db in try Int64.fetchAll(db, sql: "SELECT profile_id FROM sync_profile_results") }
        #expect(remaining == [b])
    }

    @Test func duplicateCopiesArtworkButNoResult() async throws {
        let (_, sync, results) = try make()
        let a = try await sync.create(name: "A", outputFolder: "/tmp/a").id!
        try await sync.updateSettings(profileId: a, artworkMode: "resize_250")
        try await results.begin(profileID: a, startedAt: Date(), plannedCount: 1, plan: nil, operationID: nil)
        let copy = try await sync.duplicate(id: a)
        #expect(copy.artworkMode == "resize_250")
        #expect(try await results.fetch(profileID: copy.id!) == nil)
    }
}
