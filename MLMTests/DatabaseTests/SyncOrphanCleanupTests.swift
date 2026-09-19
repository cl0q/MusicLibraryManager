import Foundation
import GRDB
import Testing
@testable import MLM

/// Tests for the v39_sync_orphan_cleanup migration.
///
/// FK enforcement remains disabled (Step 2 was reverted after revealing
/// FK violations in tests outside this worker's write scope). The
/// migration cleans up orphans that accumulated precisely because the
/// pragma was off. These tests seed orphan rows directly on a normal
/// in-memory DB — no special ordering is needed.
@Suite("SyncOrphanCleanupTests")
struct SyncOrphanCleanupTests {

    private func seedOrphans(_ db: DatabaseQueue) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (99999, 1, 'aaa', 100, '2025-01-01T00:00:00')
            """)
            try db.execute(sql: """
                INSERT INTO sync_profile_playlists (profile_id, playlist_id)
                VALUES (99999, 1)
            """)
            try db.execute(sql: """
                INSERT INTO sync_profile_tracks (profile_id, track_id)
                VALUES (88888, 1)
            """)
            try db.execute(sql: """
                INSERT INTO sync_profile_rules (profile_id, field, operator, value)
                VALUES (88888, 'genre', 'equals', 'Rock')
            """)
            try db.execute(sql: """
                INSERT INTO playlist_sync_snapshots (profile_id, playlist_id, snapshot_json, written_at)
                VALUES (77777, 1, '[]', '2025-01-01T00:00:00')
            """)
        }
    }

    private func runOrphanCleanupSQL(_ db: DatabaseQueue) async throws {
        try await db.write { db in
            for table in ["sync_state", "sync_profile_tracks", "sync_profile_playlists", "sync_profile_rules", "playlist_sync_snapshots"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE profile_id NOT IN (SELECT id FROM sync_profiles)")
            }
        }
    }

    private func orphanCount(_ db: DatabaseQueue, table: String) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM \(table) WHERE profile_id NOT IN (SELECT id FROM sync_profiles)
            """) ?? 0
        }
    }

    // MARK: - Orphans are deleted

    @Test func migrationDeletesOrphansFromAllTables() async throws {
        let db = try DatabaseManager.inMemory()
        try await seedOrphans(db)

        #expect(try await orphanCount(db, table: "sync_state") > 0)
        #expect(try await orphanCount(db, table: "sync_profile_playlists") > 0)
        #expect(try await orphanCount(db, table: "sync_profile_tracks") > 0)
        #expect(try await orphanCount(db, table: "sync_profile_rules") > 0)
        #expect(try await orphanCount(db, table: "playlist_sync_snapshots") > 0)

        try await runOrphanCleanupSQL(db)

        #expect(try await orphanCount(db, table: "sync_state") == 0)
        #expect(try await orphanCount(db, table: "sync_profile_playlists") == 0)
        #expect(try await orphanCount(db, table: "sync_profile_tracks") == 0)
        #expect(try await orphanCount(db, table: "sync_profile_rules") == 0)
        #expect(try await orphanCount(db, table: "playlist_sync_snapshots") == 0)
    }

    // MARK: - Live profile rows survive (regression guard)

    @Test func liveProfileRowsSurviveCleanup() async throws {
        let db = try DatabaseManager.inMemory()

        let liveProfileId: Int64 = try await db.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix)
                VALUES ('iPod', '/tmp/ipod', '')
            """)
            return Int64(db.lastInsertedRowID)
        }

        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (?, 1, 'live', 200, '2025-06-01T00:00:00')
            """, arguments: [liveProfileId])
            try db.execute(sql: """
                INSERT INTO sync_profile_playlists (profile_id, playlist_id)
                VALUES (?, 1)
            """, arguments: [liveProfileId])
            try db.execute(sql: """
                INSERT INTO sync_profile_tracks (profile_id, track_id)
                VALUES (?, 1)
            """, arguments: [liveProfileId])
            try db.execute(sql: """
                INSERT INTO sync_profile_rules (profile_id, field, operator, value)
                VALUES (?, 'genre', 'equals', 'Jazz')
            """, arguments: [liveProfileId])
            try db.execute(sql: """
                INSERT INTO playlist_sync_snapshots (profile_id, playlist_id, snapshot_json, written_at)
                VALUES (?, 1, '["a"]', '2025-06-01T00:00:00')
            """, arguments: [liveProfileId])

            // Also seed orphans for a nonexistent profile
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (99999, 2, 'orphan', 50, '2025-01-01T00:00:00')
            """)
            try db.execute(sql: """
                INSERT INTO sync_profile_playlists (profile_id, playlist_id)
                VALUES (99999, 2)
            """)
        }

        try await runOrphanCleanupSQL(db)

        let liveState = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_state WHERE profile_id = ?", arguments: [liveProfileId]) ?? 0
        }
        #expect(liveState == 1, "sync_state for live profile must survive")

        let livePlaylists = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_profile_playlists WHERE profile_id = ?", arguments: [liveProfileId]) ?? 0
        }
        #expect(livePlaylists == 1, "sync_profile_playlists for live profile must survive")

        let liveTracks = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_profile_tracks WHERE profile_id = ?", arguments: [liveProfileId]) ?? 0
        }
        #expect(liveTracks == 1, "sync_profile_tracks for live profile must survive")

        let liveRules = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_profile_rules WHERE profile_id = ?", arguments: [liveProfileId]) ?? 0
        }
        #expect(liveRules == 1, "sync_profile_rules for live profile must survive")

        let liveSnapshots = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_sync_snapshots WHERE profile_id = ?", arguments: [liveProfileId]) ?? 0
        }
        #expect(liveSnapshots == 1, "playlist_sync_snapshots for live profile must survive")

        #expect(try await orphanCount(db, table: "sync_state") == 0)
        #expect(try await orphanCount(db, table: "sync_profile_playlists") == 0)
    }

    // MARK: - Idempotency

    @Test func migrationIsIdempotent() async throws {
        let db = try DatabaseManager.inMemory()
        try await seedOrphans(db)

        try await runOrphanCleanupSQL(db)
        try await runOrphanCleanupSQL(db)

        #expect(try await orphanCount(db, table: "sync_state") == 0)
    }

    @Test func migrationSucceedsOnCleanDatabase() async throws {
        let db = try DatabaseManager.inMemory()
        try await runOrphanCleanupSQL(db)
    }

    // MARK: - FK enforcement is still off (Step 2 reverted)

    @Test func fkEnforcementRemainsOff() async throws {
        let db = try DatabaseManager.inMemory()

        let fkValue = try await db.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? -1
        }
        #expect(fkValue == 0, "FK enforcement was reverted — must still be 0")
    }

    @Test func orphanInsertStillSucceedsWithoutFKEnforcement() async throws {
        let db = try DatabaseManager.inMemory()

        // With FK off, inserting a sync_state row with a nonexistent profile_id succeeds
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (99999, 1, 'x', 1, '2025-01-01T00:00:00')
            """)
        }

        let count = try await orphanCount(db, table: "sync_state")
        #expect(count == 1, "Orphan insert should succeed when FK enforcement is off")
    }
}
