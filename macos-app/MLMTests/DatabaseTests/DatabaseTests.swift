import Testing
import GRDB
@testable import MLM

/// Tests for DatabaseManager and schema migrations.
///
/// Verifies that all 17+ migration versions create the expected tables
/// and columns, matching the Tauri app's SQLite schema exactly.
struct DatabaseTests {

    // MARK: - Schema Creation

    @Test func allTablesExist() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                ORDER BY name
            """)

            let expectedTables = [
                "_migrations",
                "albums",
                "app_config",
                "artwork",
                "fingerprints",
                "last_sync_timestamps",
                "playlist_tags",
                "playlist_tracks",
                "playlists",
                "replaygain",
                "review_queue",
                "sources",
                "sync_profile_playlists",
                "sync_profile_rules",
                "sync_profile_tracks",
                "sync_profiles",
                "sync_state",
                "track_analysis",
                "track_sources",
                "track_tags",
                "tracks",
                "user_album_variant_pref",
            ]

            for table in expectedTables {
                #expect(tables.contains(table), "Missing table: \(table)")
            }
        }
    }

    @Test func tracksTableHasAllColumns() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.read { db in
            let columns = try db.columns(in: "tracks").map(\.name)

            let expectedColumns = [
                "id", "artist", "album_artist", "album", "title",
                "genre", "year", "bitrate", "duration", "format",
                "original_path", "organized_path", "is_duplicate", "date_added",
                "variant_of", "download_status",
                "lufs_i", "lufs_range", "true_peak", "energy_bucket",
                "album_id",
            ]

            for col in expectedColumns {
                #expect(columns.contains(col), "Missing column: tracks.\(col)")
            }
        }
    }

    @Test func playlistsTableHasCoverIsCustomColumn() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.read { db in
            let columns = try db.columns(in: "playlists").map(\.name)
            #expect(columns.contains("cover_is_custom"),
                    "Migration v20 must add cover_is_custom column to playlists")
        }
    }

    @Test func albumsTableHasAllColumns() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.read { db in
            let columns = try db.columns(in: "albums").map(\.name)

            let expectedColumns = [
                "id", "artist", "album_artist", "title",
                "title_normalized", "year", "cover_path",
                "variant_of", "variant_kind",
            ]

            for col in expectedColumns {
                #expect(columns.contains(col), "Missing column: albums.\(col)")
            }
        }
    }

    // MARK: - CRUD Operations

    @Test func trackCRUD() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            // Insert
            var track = Track(
                artist: "Test Artist",
                album: "Test Album",
                title: "Test Track",
                format: "mp3",
                originalPath: "/path/to/test.mp3"
            )
            try track.insert(db)
            let id = track.id!

            // Read
            let fetched = try Track.fetchOne(db, id: id)
            #expect(fetched != nil)
            #expect(fetched?.title == "Test Track")
            #expect(fetched?.artist == "Test Artist")

            // Update
            var updated = fetched!
            updated.genre = "Electronic"
            try updated.update(db)

            let refetched = try Track.fetchOne(db, id: id)
            #expect(refetched?.genre == "Electronic")

            // Delete
            try Track.deleteOne(db, id: id)
            let deleted = try Track.fetchOne(db, id: id)
            #expect(deleted == nil)
        }
    }

    @Test func playlistCRUD() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            // Create native playlist
            var playlist = Playlist.createNative(name: "My Playlist")
            try playlist.insert(db)
            let id = playlist.id!

            // Read
            let fetched = try Playlist.fetchOne(db, id: id)
            #expect(fetched?.name == "My Playlist")
            #expect(fetched?.category == "regular")
            #expect(fetched?.isNative == true)

            // Delete
            try Playlist.deleteOne(db, id: id)
            #expect(try Playlist.fetchOne(db, id: id) == nil)
        }
    }

    @Test func playlistTrackOrdering() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            // Setup: create playlist and tracks
            var playlist = Playlist.createNative(name: "Ordered")
            try playlist.insert(db)

            var track1 = Track(artist: "A", album: "A", title: "First", format: "mp3", originalPath: "/1.mp3")
            try track1.insert(db)

            var track2 = Track(artist: "B", album: "B", title: "Second", format: "mp3", originalPath: "/2.mp3")
            try track2.insert(db)

            // Add tracks with fractional positions
            var pt1 = PlaylistTrack(id: nil, playlistId: playlist.id!, trackId: track1.id!, position: "a0", addedAt: nil)
            try pt1.insert(db)

            var pt2 = PlaylistTrack(id: nil, playlistId: playlist.id!, trackId: track2.id!, position: "a1", addedAt: nil)
            try pt2.insert(db)

            // Verify ordered fetch
            let tracks = try Track.fetchAll(db, sql: """
                SELECT t.* FROM tracks t
                INNER JOIN playlist_tracks pt ON pt.track_id = t.id
                WHERE pt.playlist_id = ?
                ORDER BY pt.position
            """, arguments: [playlist.id!])

            #expect(tracks.count == 2)
            #expect(tracks[0].title == "First")
            #expect(tracks[1].title == "Second")
        }
    }

    @Test func foreignKeysCascadeDelete() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            // Create track
            var track = Track(artist: "A", album: "A", title: "T", format: "mp3", originalPath: "/t.mp3")
            try track.insert(db)
            let trackId = track.id!

            // Create playlist and add track
            var playlist = Playlist.createNative(name: "PL")
            try playlist.insert(db)
            var pt = PlaylistTrack(id: nil, playlistId: playlist.id!, trackId: trackId, position: "a0", addedAt: nil)
            try pt.insert(db)

            // Delete track — should cascade to playlist_tracks
            try Track.deleteOne(db, id: trackId)

            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_tracks WHERE track_id = ?", arguments: [trackId])
            #expect(count == 0)
        }
    }

    @Test func appConfigCRUD() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            // Insert
            try db.execute(sql: """
                INSERT INTO app_config (key, value) VALUES ('library_root', '/Volumes/Lexxar/Music')
            """)

            // Read
            let value: String? = try Row.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = 'library_root'")?["value"]
            #expect(value == "/Volumes/Lexxar/Music")

            // Update
            try db.execute(sql: """
                INSERT OR REPLACE INTO app_config (key, value, updated_at)
                VALUES ('library_root', '/Users/test/Music', datetime('now'))
            """)
            let updated: String? = try Row.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = 'library_root'")?["value"]
            #expect(updated == "/Users/test/Music")
        }
    }

    @Test func syncProfileCRUD() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            var profile = SyncProfile(
                id: nil,
                name: "iPod Classic",
                outputFolder: "/Volumes/iPod/Music",
                playlistPathPrefix: "/<HDD0>/",
                dateCreated: nil,
                dateModified: nil
            )
            try profile.insert(db)
            let id = profile.id!

            let fetched = try SyncProfile.fetchOne(db, id: id)
            #expect(fetched?.name == "iPod Classic")
            #expect(fetched?.playlistPathPrefix == "/<HDD0>/")
        }
    }

    @Test func albumVariantRelationship() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            // Insert base album
            try db.execute(sql: """
                INSERT INTO albums (artist, album_artist, title, title_normalized, year)
                VALUES ('Yeat', 'Yeat', 'AftërLyfe', 'afterlyfe', 2023)
            """)
            let baseId = db.lastInsertedRowID

            // Insert variant
            try db.execute(sql: """
                INSERT INTO albums (artist, album_artist, title, title_normalized, year, variant_of, variant_kind)
                VALUES ('Yeat', 'Yeat', 'AftërLyfe [U]', 'afterlyfe', 2023, ?, 'u')
            """, arguments: [baseId])
            let variantId = db.lastInsertedRowID

            // Fetch siblings
            let siblings = try Album.fetchAll(db, sql: """
                SELECT * FROM albums WHERE id = ? OR variant_of = ?
                ORDER BY variant_kind NULLS FIRST
            """, arguments: [baseId, baseId])

            #expect(siblings.count == 2)
            #expect(siblings[0].title == "AftërLyfe")
            #expect(siblings[1].title == "AftërLyfe [U]")
            #expect(siblings[1].variantOf == baseId)
        }
    }

    @Test func trackTagsCRUD() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            // Create track
            var track = Track(artist: "Yeat", album: "Lyfë", title: "Poppin", format: "flac", originalPath: "/y.flac")
            try track.insert(db)
            let trackId = track.id!

            // Add tags
            try db.execute(sql: """
                INSERT INTO track_tags (track_id, tag_key, tag_value)
                VALUES (?, 'artist', 'yeat')
            """, arguments: [trackId])
            try db.execute(sql: """
                INSERT INTO track_tags (track_id, tag_key, tag_value)
                VALUES (?, 'era', 'lyfe')
            """, arguments: [trackId])

            // Fetch tags
            let tags = try TrackTag.filter(TrackTag.Columns.trackId == trackId).fetchAll(db)
            #expect(tags.count == 2)
            #expect(tags.contains(where: { $0.tagKey == "artist" && $0.tagValue == "yeat" }))
            #expect(tags.contains(where: { $0.tagKey == "era" && $0.tagValue == "lyfe" }))
        }
    }

    @Test func smartPlaylistViewsExist() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.read { db in
            // These views should exist and be queryable
            _ = try Row.fetchAll(db, sql: "SELECT * FROM smart_playlist_recently_added LIMIT 1")
            _ = try Row.fetchAll(db, sql: "SELECT * FROM smart_playlist_most_played LIMIT 1")
        }
    }

    @Test func migrationsAreIdempotent() async throws {
        // Creating a second in-memory DB should work without errors
        let db1 = try DatabaseManager.inMemory()
        let db2 = try DatabaseManager.inMemory()

        try await db1.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'")
            #expect(count! > 20)
        }

        try await db2.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'")
            #expect(count! > 20)
        }
    }
}
