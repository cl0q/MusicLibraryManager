import Foundation
import GRDB
import Testing
@testable import MLM

/// Repository support for undo (W2-F): the Delete Playlist snapshot covers every table that
/// refers to a playlist, a restore puts back the exact rows, and add-to-playlist undo removes
/// exactly the rows it added. Temporary in-memory databases only.
@Suite("Playlist undo snapshots")
struct PlaylistUndoRepositoryTests {
    private func makeRepo() throws -> (DatabaseQueue, PlaylistRepository) {
        let db = try DatabaseManager.inMemory()
        return (db, PlaylistRepository(database: db))
    }

    private func seedTracks(_ db: DatabaseQueue, _ ids: [Int64]) async throws {
        try await db.write { db in
            for id in ids {
                try db.execute(sql: """
                    INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, date_added)
                    VALUES (?, 'A', 'A', 'Album', 'Track \(id)', 'mp3', '/tmp/\(id).mp3', '2025-01-01T00:00:00Z')
                """, arguments: [id])
            }
        }
    }

    /// Each row's values, in column order (`Row` itself isn't Sendable).
    private func entries(_ db: DatabaseQueue, playlist: Int64) async throws -> [[DatabaseValue]] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, playlist_id, track_id, position, added_at FROM playlist_tracks
                WHERE playlist_id = ? ORDER BY position, added_at, id
            """, arguments: [playlist]).map { Array($0.databaseValues) }
        }
    }

    private func count(_ db: DatabaseQueue, _ table: String, playlist: Int64) async throws -> Int {
        try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE playlist_id = ?", arguments: [playlist]) ?? 0
        }
    }

    /// A playlist with every kind of dependent row: tracks at hand-picked positions, tags,
    /// two sync profile links, a device-ingest snapshot, source link, custom cover, pin, uuid.
    private func seedFullPlaylist(_ db: DatabaseQueue, repo: PlaylistRepository) async throws -> (playlistID: Int64, profileIDs: [Int64]) {
        try await seedTracks(db, [1, 2, 3])
        let playlist = try await repo.create(name: "Warm-up")
        let id = try #require(playlist.id)
        let profiles = try await db.write { db -> [Int64] in
            try db.execute(sql: "INSERT INTO sources (name, user_id) VALUES ('soundcloud', 'me')")
            let sourceID = db.lastInsertedRowID
            try db.execute(sql: """
                UPDATE playlists SET source_id = ?, external_id = 'ext-1', cover_image_path = 'playlist-covers/\(id).png',
                cover_is_custom = 1, is_pinned = 1, mlm_uuid = 'UUID-1', description = 'Morning' WHERE id = ?
            """, arguments: [sourceID, id])
            try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, added_at) VALUES (?, 3, 'a0', '2024-01-01 10:00:00')", arguments: [id])
            try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, added_at) VALUES (?, 1, 'a0V', '2024-01-02 10:00:00')", arguments: [id])
            try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, added_at) VALUES (?, 2, 'a1', '2024-01-03 10:00:00')", arguments: [id])
            try db.execute(sql: "INSERT INTO playlist_tags (playlist_id, tag) VALUES (?, 'techno'), (?, 'morning')", arguments: [id, id])
            var ids: [Int64] = []
            for name in ["iPod Classic", "Laptop"] {
                try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder) VALUES (?, '/tmp/out')", arguments: [name])
                ids.append(db.lastInsertedRowID)
                try db.execute(sql: "INSERT INTO sync_profile_playlists (profile_id, playlist_id) VALUES (?, ?)", arguments: [db.lastInsertedRowID, id])
            }
            try db.execute(sql: """
                INSERT INTO playlist_sync_snapshots (profile_id, playlist_id, playlist_uuid, snapshot_json, written_at)
                VALUES (?, ?, 'UUID-1', '["a","b"]', '2024-02-01 12:00:00.000')
            """, arguments: [ids[0], id])
            return ids
        }
        return (id, profiles)
    }

    // MARK: Coverage of the schema

    @Test func theSnapshotCoversEveryTableThatRefersToAPlaylist() async throws {
        let (db, _) = try makeRepo()
        let referencing = try await db.read { db -> Set<String> in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
            var found: Set<String> = []
            for table in tables where table != "playlists" {
                let columns = try db.columns(in: table).map(\.name)
                if columns.contains("playlist_id") { found.insert(table) }
            }
            return found
        }
        #expect(referencing == Set(PlaylistRepository.dependentTables))
    }

    // MARK: Delete → restore

    @Test func deleteAndRestoreBringBackExactlyThePlaylistAndEveryDependentRow() async throws {
        let (db, repo) = try makeRepo()
        let (id, profiles) = try await seedFullPlaylist(db, repo: repo)
        let before = try #require(try await repo.fetch(id: id))
        let entriesBefore = try await entries(db, playlist: id)
        let syncSnapshotsBefore = try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM playlist_sync_snapshots WHERE playlist_id = ?", arguments: [id])
                .map { Array($0.databaseValues) }
        }

        let snapshot = try await repo.deleteReturningSnapshot(id: id)
        #expect(try await repo.fetch(id: id) == nil)
        for table in PlaylistRepository.dependentTables {
            #expect(try await count(db, table, playlist: id) == 0, "\(table) left behind")
        }
        #expect(snapshot.tags == ["morning", "techno"])
        #expect(snapshot.syncProfileIDs == profiles.sorted())

        let result = try await repo.restore(snapshot)
        #expect(result.playlist.id == id)
        #expect(!result.wasRenamed)
        #expect(result.droppedTrackCount == 0)
        #expect(try await repo.fetch(id: id) == before)
        #expect(try await entries(db, playlist: id) == entriesBefore)
        #expect(try await db.read { db in
            try String.fetchAll(db, sql: "SELECT tag FROM playlist_tags WHERE playlist_id = ? ORDER BY tag", arguments: [id])
        } == ["morning", "techno"])
        #expect(try await db.read { db in
            try Int64.fetchAll(db, sql: "SELECT profile_id FROM sync_profile_playlists WHERE playlist_id = ? ORDER BY profile_id", arguments: [id])
        } == profiles.sorted())
        #expect(try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM playlist_sync_snapshots WHERE playlist_id = ?", arguments: [id])
                .map { Array($0.databaseValues) }
        } == syncSnapshotsBefore)
    }

    @Test func deleteRestoreDeleteAgainIsRepeatable() async throws {
        let (db, repo) = try makeRepo()
        let (id, _) = try await seedFullPlaylist(db, repo: repo)
        let entriesBefore = try await entries(db, playlist: id)
        let first = try await repo.deleteReturningSnapshot(id: id)
        _ = try await repo.restore(first)
        let second = try await repo.deleteReturningSnapshot(id: id)
        _ = try await repo.restore(second)
        #expect(try await entries(db, playlist: id) == entriesBefore)
    }

    @Test func aRestoreWhoseNameWasTakenUsesTheFirstFreeNumberedName() async throws {
        let (db, repo) = try makeRepo()
        let (id, _) = try await seedFullPlaylist(db, repo: repo)
        let snapshot = try await repo.deleteReturningSnapshot(id: id)
        _ = try await repo.create(name: "Warm-up")
        let result = try await repo.restore(snapshot)
        #expect(result.wasRenamed)
        #expect(result.playlist.name == "Warm-up 2")
        #expect(result.playlist.id == id)
    }

    @Test func aRestoreWhoseIdWasTakenGetsANewIdAndDropsTheOldAutoCover() async throws {
        let (db, repo) = try makeRepo()
        try await seedTracks(db, [1])
        let playlist = try await repo.create(name: "Sets")
        let id = try #require(playlist.id)
        try await repo.setCoverPath(id: id, path: "playlist-covers/\(id).png", isCustom: false)
        try await repo.addTrack(playlistId: id, trackId: 1, position: "a0")
        let snapshot = try await repo.deleteReturningSnapshot(id: id)
        try await db.write { db in
            try db.execute(sql: "INSERT INTO playlists (id, name, category) VALUES (?, 'Other', 'regular')", arguments: [id])
        }
        let result = try await repo.restore(snapshot)
        let newID = try #require(result.playlist.id)
        #expect(newID != id)
        #expect(result.playlist.coverImagePath == nil)
        #expect(try await repo.fetchTracks(playlistId: newID).compactMap(\.id) == [1])
        #expect(try await repo.fetch(id: id)?.name == "Other")
    }

    @Test func aRestoreSkipsTracksAndProfilesThatAreGoneMeanwhile() async throws {
        let (db, repo) = try makeRepo()
        let (id, profiles) = try await seedFullPlaylist(db, repo: repo)
        let snapshot = try await repo.deleteReturningSnapshot(id: id)
        try await db.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE id = 2")
            try db.execute(sql: "DELETE FROM sync_profiles WHERE id = ?", arguments: [profiles[0]])
        }
        let result = try await repo.restore(snapshot)
        #expect(result.droppedTrackCount == 1)
        #expect(try await repo.fetchTracks(playlistId: id).compactMap(\.id) == [3, 1])
        #expect(try await count(db, "sync_profile_playlists", playlist: id) == 1)
        #expect(try await count(db, "playlist_sync_snapshots", playlist: id) == 0)
    }

    @Test func theLikedPlaylistIsNotDeletedBySnapshotDelete() async throws {
        let (_, repo) = try makeRepo()
        let liked = try await repo.findOrCreateLikedPlaylist(name: "Liked from SoundCloud", sourceId: 1, externalId: nil)
        await #expect(throws: PlaylistRepositoryError.self) {
            _ = try await repo.deleteReturningSnapshot(id: liked.id!)
        }
        #expect(try await repo.fetch(id: liked.id!) != nil)
    }

    @Test func deletionImpactCountsTracksAndNamesTheSyncProfiles() async throws {
        let (db, repo) = try makeRepo()
        let (id, _) = try await seedFullPlaylist(db, repo: repo)
        let impact = try await repo.deletionImpact(id: id)
        #expect(impact == PlaylistDeletionImpact(trackCount: 3, syncProfileNames: ["Laptop", "iPod Classic"].sorted()))
    }

    // MARK: Create, append, exact rows

    @Test func createNumberedKeepsTheTrackOrderAndNumbersTakenNames() async throws {
        let (db, repo) = try makeRepo()
        try await seedTracks(db, [1, 2, 3])
        let first = try await repo.createNumbered(baseName: "Untitled Playlist", trackIds: [3, 1, 3, 2])
        let second = try await repo.createNumbered(baseName: "Untitled Playlist")
        #expect(first.name == "Untitled Playlist")
        #expect(second.name == "Untitled Playlist 2")
        #expect(try await repo.fetchTracks(playlistId: first.id!).compactMap(\.id) == [3, 1, 2])
    }

    @Test func appendReportsExactlyTheRowsItAddedAndWhatWasAlreadyThere() async throws {
        let (db, repo) = try makeRepo()
        try await seedTracks(db, [1, 2, 3])
        let playlist = try await repo.create(name: "Warm-up")
        let id = playlist.id!
        try await repo.addTrack(playlistId: id, trackId: 2, position: "a0")
        let before = try await entries(db, playlist: id)

        let result = try await repo.appendTracksReturningEntries(playlistId: id, trackIds: [1, 2, 3])
        #expect(result.alreadyPresent == 1)
        #expect(result.entries.map(\.trackId) == [1, 3])
        #expect(try await repo.fetchTracks(playlistId: id).compactMap(\.id) == [2, 1, 3])

        // Undo: only the two added rows go; the track that was already there stays.
        let removed = try await repo.removeEntries(result.entries)
        #expect(removed.map(\.trackId) == [1, 3])
        #expect(try await entries(db, playlist: id) == before)

        // Redo: the same rows come back with their ids, positions and added_at.
        let restored = try await repo.restoreEntries(removed)
        #expect(restored.map(\.id) == result.entries.map(\.id))
        #expect(restored.map(\.position) == result.entries.map(\.position))
        #expect(restored.map(\.addedAt) == result.entries.map(\.addedAt))
        #expect(try await repo.fetchTracks(playlistId: id).compactMap(\.id) == [2, 1, 3])
    }

    @Test func removeEntriesNeverTouchesAnotherRowOfTheSameTrack() async throws {
        let (db, repo) = try makeRepo()
        try await seedTracks(db, [1])
        let id = try await repo.create(name: "Warm-up").id!
        let added = try await repo.appendTracksReturningEntries(playlistId: id, trackIds: [1])
        _ = try await repo.removeEntries(added.entries)
        // The track is added again by another route; the stale undo must leave it.
        try await repo.addTrack(playlistId: id, trackId: 1, position: "b0")
        #expect(try await repo.removeEntries(added.entries).isEmpty)
        #expect(try await repo.fetchTracks(playlistId: id).compactMap(\.id) == [1])
        // And a redo doesn't add a second copy.
        #expect(try await repo.restoreEntries(added.entries).isEmpty)
        #expect(try await count(db, "playlist_tracks", playlist: id) == 1)
    }
}
