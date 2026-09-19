import Foundation
import GRDB
import Testing
@testable import MLM

@Suite("Sync profile cascade delete")
struct SyncProfileCascadeTests {
    private func makeRepo() throws -> (any DatabaseWriter, SyncRepository) {
        let database = try DatabaseManager.inMemory()
        return (database, SyncRepository(database: database))
    }

    private func insertProfile(_ db: any DatabaseWriter, name: String) async throws -> Int64 {
        try await db.write { db in
            var profile = SyncProfile(
                id: nil,
                name: name,
                outputFolder: "/tmp/\(name)",
                playlistPathPrefix: "",
                dateCreated: nil,
                dateModified: nil
            )
            try profile.insert(db)
            return profile.id!
        }
    }

    private func insertChildRows(_ db: any DatabaseWriter, profileId: Int64) async throws {
        try await db.write { db in
            try db.execute(
                sql: "INSERT INTO sync_profile_tracks (profile_id, track_id) VALUES (?, ?)",
                arguments: [profileId, 100]
            )
            try db.execute(
                sql: "INSERT INTO sync_profile_playlists (profile_id, playlist_id) VALUES (?, ?)",
                arguments: [profileId, 200]
            )
            try db.execute(
                sql: "INSERT INTO sync_profile_rules (profile_id, field, operator, value) VALUES (?, ?, ?, ?)",
                arguments: [profileId, "genre", "equals", "Rock"]
            )
            try db.execute(
                sql: """
                    INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [profileId, 100, "abc123", 1024, "2025-01-01T00:00:00"]
            )
            try db.execute(
                sql: """
                    INSERT INTO playlist_sync_snapshots (profile_id, playlist_id, snapshot_json, written_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [profileId, 200, "[]", Date()]
            )
        }
    }

    private func countRows(_ db: any DatabaseWriter, table: String, profileId: Int64) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(table) WHERE profile_id = ?",
                arguments: [profileId]
            ) ?? 0
        }
    }

    @Test func deleteRemovesAllChildRowsForDeletedProfileOnly() async throws {
        let (db, repo) = try makeRepo()
        let profileA = try await insertProfile(db, name: "Alpha")
        let profileB = try await insertProfile(db, name: "Beta")

        try await insertChildRows(db, profileId: profileA)
        try await insertChildRows(db, profileId: profileB)

        try await repo.delete(id: profileA)

        for table in ["sync_state", "sync_profile_tracks", "sync_profile_playlists", "sync_profile_rules", "playlist_sync_snapshots"] {
            let countA = try await countRows(db, table: table, profileId: profileA)
            #expect(countA == 0, "\(table) still has rows for deleted profile \(profileA)")

            let countB = try await countRows(db, table: table, profileId: profileB)
            #expect(countB > 0, "\(table) lost rows for surviving profile \(profileB)")
        }
    }

    @Test func deleteRemovesProfileRowItself() async throws {
        let (db, repo) = try makeRepo()
        let profileId = try await insertProfile(db, name: "Gamma")

        try await repo.delete(id: profileId)

        let fetched = try await repo.fetch(id: profileId)
        #expect(fetched == nil)
    }

    @Test func fetchLastSyncTimestampsExcludesOrphans() async throws {
        let (db, repo) = try makeRepo()
        let liveProfile = try await insertProfile(db, name: "Live")

        try await db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [liveProfile, 10, "aa", 512, "2025-06-01T12:00:00"]
            )
            let orphanProfileId: Int64 = 99_999
            try db.execute(
                sql: """
                    INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [orphanProfileId, 20, "bb", 256, "2025-07-01T12:00:00"]
            )
        }

        let timestamps = try await repo.fetchLastSyncTimestamps()
        #expect(timestamps[liveProfile] == "2025-06-01T12:00:00")
        #expect(timestamps[99_999] == nil, "Orphan profile id should not appear in timestamps")
    }

    @Test func fetchLastSyncTimestampsReturnsMaxPerProfile() async throws {
        let (db, repo) = try makeRepo()
        let profile = try await insertProfile(db, name: "Multi")

        try await db.write { db in
            for ts in ["2025-01-01T00:00:00", "2025-06-15T00:00:00", "2025-03-10T00:00:00"] {
                try db.execute(
                    sql: """
                        INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [profile, Int64.random(in: 1...9999), "x", 1, ts]
                )
            }
        }

        let timestamps = try await repo.fetchLastSyncTimestamps()
        #expect(timestamps[profile] == "2025-06-15T00:00:00")
    }
}
