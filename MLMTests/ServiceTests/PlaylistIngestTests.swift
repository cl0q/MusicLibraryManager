import Testing
import Foundation
import GRDB
@testable import MLM

@Suite("PlaylistIngestTests")
@MainActor
struct PlaylistIngestTests {

    // MARK: - Helpers

    private func makeService() throws -> (DatabaseQueue, PlaylistIngestService, TrackRepository, PlaylistRepository) {
        let db = try DatabaseManager.inMemory()
        let trackRepo = TrackRepository(database: db)
        let playlistRepo = PlaylistRepository(database: db)
        let service = PlaylistIngestService(
            trackRepository: trackRepo,
            playlistRepository: playlistRepo,
            database: db
        )
        return (db, service, trackRepo, playlistRepo)
    }

    private func seedTrack(
        db: DatabaseQueue,
        id: Int64,
        artist: String,
        title: String,
        album: String = "Album",
        format: String = "m4a",
        uuid: String? = nil,
        originalPath: String? = nil
    ) async throws {
        let path = originalPath ?? "/music/\(artist)/\(album)/\(title).\(format)"
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, duration, original_path, is_duplicate, mlm_uuid)
                VALUES (?, ?, ?, ?, ?, ?, 200, ?, 0, ?)
                """, arguments: [id, artist, artist, album, title, format, path, uuid])
        }
    }

    private func seedPlaylist(
        db: DatabaseQueue,
        id: Int64,
        name: String,
        uuid: String? = nil,
        category: String = "regular"
    ) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO playlists (id, name, category, mlm_uuid) VALUES (?, ?, ?, ?)
                """, arguments: [id, name, category, uuid])
        }
    }

    private func writeM3U8(to url: URL, content: String) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Parse Tests

    @Test func parseIOSDialect() throws {
        let (db, service, _, _) = try makeService()
        _ = db

        let content = """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-UUID-001
        #EXTINF:200,Artist A - Track One
        #EXTMLM:TRACK-UUID-001
        Artist A/Album/Track One.m4a
        #EXTINF:180,Artist B - Track Two
        #EXTMLM:TRACK-UUID-002
        Artist B/Album/Track Two.mp3
        """

        let (header, entries) = service.parse(content: content)
        #expect(header.playlistUuid == "PL-UUID-001")
        #expect(entries.count == 2)
        #expect(entries[0].uuid == "TRACK-UUID-001")
        #expect(entries[0].path == "Artist A/Album/Track One.m4a")
        #expect(entries[0].artist == "Artist A")
        #expect(entries[0].title == "Track One")
        #expect(entries[1].uuid == "TRACK-UUID-002")
        #expect(entries[1].path == "Artist B/Album/Track Two.mp3")
    }

    @Test func parseLegacyPlainM3U8() throws {
        let (_, service, _, _) = try makeService()

        let content = """
        #EXTM3U
        #EXTINF:200,Artist - Title
        Music/Artist/Album/Song.m4a
        #EXTINF:180,Another Artist - Another Song
        Music/Another Artist/Album/Another Song.mp3
        """

        let (header, entries) = service.parse(content: content)
        #expect(header.playlistUuid == nil)
        #expect(entries.count == 2)
        #expect(entries[0].uuid == nil)
        #expect(entries[0].path == "Music/Artist/Album/Song.m4a")
        #expect(entries[0].artist == "Artist")
        #expect(entries[0].title == "Title")
    }

    @Test func parseMixedDialect() throws {
        let (_, service, _, _) = try makeService()

        // First entry has EXTMLM, second doesn't (mixed scenario)
        let content = """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-UUID
        #EXTINF:200,Artist - Known
        #EXTMLM:TRACK-UUID-1
        Artist/Album/Known.m4a
        #EXTINF:180,Artist - Unknown
        Artist/Album/Unknown.m4a
        """

        let (header, entries) = service.parse(content: content)
        #expect(header.playlistUuid == "PL-UUID")
        #expect(entries.count == 2)
        #expect(entries[0].uuid == "TRACK-UUID-1")
        #expect(entries[1].uuid == nil)
    }

    // MARK: - Resolution Tests

    @Test func resolutionUuidMatchWins() async throws {
        let (db, service, _, _) = try makeService()

        try await seedTrack(db: db, id: 1001, artist: "Artist", title: "Song", uuid: "UUID-A")

        let entries = [
            PlaylistIngestService.ParsedEntry(uuid: "UUID-A", path: "wrong/path.m4a", title: nil, artist: nil)
        ]

        let (resolved, unresolved) = try await service.resolveEntries(entries)
        #expect(resolved.count == 1)
        #expect(resolved[0].track.id == 1001)
        #expect(unresolved.isEmpty)
    }

    @Test func resolutionFilenameFallbackCaseInsensitive() async throws {
        let (db, service, _, _) = try makeService()

        try await seedTrack(
            db: db, id: 1002, artist: "artist", title: "song",
            originalPath: "/music/Artist/Album/Song.m4a"
        )

        // No UUID, path differs in case
        let entries = [
            PlaylistIngestService.ParsedEntry(uuid: nil, path: "Artist/Album/song.m4a", title: nil, artist: nil)
        ]

        let (resolved, unresolved) = try await service.resolveEntries(entries)
        #expect(resolved.count == 1)
        #expect(resolved[0].track.id == 1002)
        #expect(unresolved.isEmpty)
    }

    @Test func resolutionUnknownEntryGoesToUnresolved() async throws {
        let (db, service, _, _) = try makeService()
        _ = db

        let entries = [
            PlaylistIngestService.ParsedEntry(uuid: "NONEXISTENT", path: "No/Such/File.m4a", title: nil, artist: nil)
        ]

        let (resolved, unresolved) = try await service.resolveEntries(entries)
        #expect(resolved.isEmpty)
        #expect(unresolved.count == 1)
        #expect(unresolved[0].entry.uuid == "NONEXISTENT")
    }

    // MARK: - Roundtrip Idempotency

    @Test func reExportIsIdempotent() async throws {
        let (db, service, _, playlistRepo) = try makeService()

        // Set up a profile with .ios format
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        // Create fake track files at the expected output paths (iOS layout: <root>/Music/...)
        let trackDir = outputDir.appendingPathComponent("Music/Artist/Album")
        try FileManager.default.createDirectory(at: trackDir, withIntermediateDirectories: true)
        let trackFile1 = trackDir.appendingPathComponent("One.m4a")
        let trackFile2 = trackDir.appendingPathComponent("Two.m4a")
        try Data(repeating: 0, count: 100).write(to: trackFile1)
        try Data(repeating: 0, count: 100).write(to: trackFile2)

        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (id, name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files, playlist_format)
                VALUES (1, 'RT', ?, '', 1, 'keep_originals', 1, 0, 'ios')
                """, arguments: [outputDir.path])
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, duration, original_path, is_duplicate, mlm_uuid)
                VALUES (11001, 'Artist', 'Artist', 'Album', 'One', 'm4a', 200, ?, 0, 'RT-U1')
                """, arguments: [trackFile1.path])
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, duration, original_path, is_duplicate, mlm_uuid)
                VALUES (11002, 'Artist', 'Artist', 'Album', 'Two', 'm4a', 180, ?, 0, 'RT-U2')
                """, arguments: [trackFile2.path])
            try db.execute(sql: """
                INSERT INTO playlists (id, name, category, mlm_uuid) VALUES (11010, 'RT PL', 'regular', 'RT-PL-U')
                """)
            try db.execute(sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (11010, 11001, 'a0')
                """)
            try db.execute(sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (11010, 11002, 'a1')
                """)
            try db.execute(sql: """
                INSERT INTO sync_profile_playlists (profile_id, playlist_id) VALUES (1, 11010)
                """)
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (1, 11001, 'abc', 100, datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (1, 11002, 'def', 100, datetime('now'))
                """)
        }

        // Step 1: Export (simulate via SyncService)
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cache = TranscodeCache(cacheDir: outputDir)
        let syncService = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )
        _ = try await syncService.executeSync(profileId: 1)

        // Read the exported playlist — iOS writes to <root>/Playlists/
        let exportedFile = outputDir.appendingPathComponent("Playlists/RT PL.m3u8")
        #expect(FileManager.default.fileExists(atPath: exportedFile.path))
        let exportedContent = try String(contentsOf: exportedFile, encoding: .utf8)

        // Step 2: Re-export should produce identical content
        _ = try await syncService.executeSync(profileId: 1)
        let reexportedContent = try String(contentsOf: exportedFile, encoding: .utf8)
        #expect(exportedContent == reexportedContent)
    }

    // MARK: - Snapshot Persistence

    @Test func snapshotWrittenAfterExport() async throws {
        let (db, service, _, _) = try makeService()
        _ = service

        // Verify the snapshot table exists and is empty initially
        let count = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_sync_snapshots") ?? 0
        }
        #expect(count == 0)

        // Write a snapshot manually
        let entries: [PlaylistIngestService.SnapshotEntry] = [
            .init(uuid: "U1", path: "A/B/C.m4a")
        ]
        try await service.writeSnapshot(profileId: 42, playlistId: 99, playlistUuid: "PL-U", entries: entries)

        // Read it back
        let snapshot = try await service.readSnapshot(profileId: 42, playlistId: 99)
        #expect(snapshot?.count == 1)
        #expect(snapshot?[0].uuid == "U1")
        #expect(snapshot?[0].path == "A/B/C.m4a")
    }

    @Test func snapshotReplacedOnSubsequentWrite() async throws {
        let (db, service, _, _) = try makeService()
        _ = db

        // Write first snapshot
        let entries1: [PlaylistIngestService.SnapshotEntry] = [.init(uuid: "U1", path: "A.m4a")]
        try await service.writeSnapshot(profileId: 1, playlistId: 1, playlistUuid: nil, entries: entries1)

        // Write second snapshot (should replace)
        let entries2: [PlaylistIngestService.SnapshotEntry] = [
            .init(uuid: "U1", path: "A.m4a"),
            .init(uuid: "U2", path: "B.m4a")
        ]
        try await service.writeSnapshot(profileId: 1, playlistId: 1, playlistUuid: nil, entries: entries2)

        let snapshot = try await service.readSnapshot(profileId: 1, playlistId: 1)
        #expect(snapshot?.count == 2)
    }
}
