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

    // MARK: - Diff Tests

    @Test func diffUnchangedFileGivesEmptyPreview() async throws {
        let (db, service, _, _) = try makeService()

        try await seedTrack(db: db, id: 2001, artist: "A", title: "One", uuid: "U1")
        try await seedTrack(db: db, id: 2002, artist: "B", title: "Two", uuid: "U2")
        try await seedPlaylist(db: db, id: 2010, name: "PL", uuid: "PL-U")

        // Write snapshot matching the incoming file
        let snapshotEntries: [PlaylistIngestService.SnapshotEntry] = [
            .init(uuid: "U1", path: "A/Album/One.m4a"),
            .init(uuid: "U2", path: "B/Album/Two.m4a")
        ]
        try await service.writeSnapshot(profileId: 1, playlistId: 2010, playlistUuid: "PL-U", entries: snapshotEntries)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("PL.m3u8")
        try writeM3U8(to: fileURL, content: """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-U
        #EXTINF:200,A - One
        #EXTMLM:U1
        A/Album/One.m4a
        #EXTINF:200,B - Two
        #EXTMLM:U2
        B/Album/Two.m4a
        """)

        let preview = try await service.preview(url: fileURL, profileId: 1)
        #expect(preview.isEmpty)
        #expect(preview.targetPlaylistId == 2010)
    }

    @Test func diffOneAdded() async throws {
        let (db, service, _, _) = try makeService()

        try await seedTrack(db: db, id: 3001, artist: "A", title: "One", uuid: "U1")
        try await seedTrack(db: db, id: 3002, artist: "B", title: "Two", uuid: "U2")
        try await seedPlaylist(db: db, id: 3010, name: "PL", uuid: "PL-U")

        // Snapshot has only track 1
        let snapshotEntries: [PlaylistIngestService.SnapshotEntry] = [
            .init(uuid: "U1", path: "A/Album/One.m4a")
        ]
        try await service.writeSnapshot(profileId: 1, playlistId: 3010, playlistUuid: "PL-U", entries: snapshotEntries)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-add-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("PL.m3u8")
        try writeM3U8(to: fileURL, content: """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-U
        #EXTINF:200,A - One
        #EXTMLM:U1
        A/Album/One.m4a
        #EXTINF:200,B - Two
        #EXTMLM:U2
        B/Album/Two.m4a
        """)

        let preview = try await service.preview(url: fileURL, profileId: 1)
        #expect(preview.added.count == 1)
        #expect(preview.added[0].id == 3002)
        #expect(preview.removed.isEmpty)
        #expect(preview.reordered.isEmpty)
    }

    @Test func diffOneRemoved() async throws {
        let (db, service, _, _) = try makeService()

        try await seedTrack(db: db, id: 4001, artist: "A", title: "One", uuid: "U1")
        try await seedPlaylist(db: db, id: 4010, name: "PL", uuid: "PL-U")

        // Snapshot has two tracks
        let snapshotEntries: [PlaylistIngestService.SnapshotEntry] = [
            .init(uuid: "U1", path: "A/Album/One.m4a"),
            .init(uuid: "U2", path: "B/Album/Two.m4a")
        ]
        try await service.writeSnapshot(profileId: 1, playlistId: 4010, playlistUuid: "PL-U", entries: snapshotEntries)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-rm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("PL.m3u8")
        // Incoming has only track 1 (track 2 removed)
        try writeM3U8(to: fileURL, content: """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-U
        #EXTINF:200,A - One
        #EXTMLM:U1
        A/Album/One.m4a
        """)

        let preview = try await service.preview(url: fileURL, profileId: 1)
        #expect(preview.added.isEmpty)
        #expect(preview.removed.count == 1)
        #expect(preview.removed[0].path == "B/Album/Two.m4a")
    }

    @Test func diffReorderOnlyDetected() async throws {
        let (db, service, _, _) = try makeService()

        try await seedTrack(db: db, id: 5001, artist: "A", title: "One", uuid: "U1")
        try await seedTrack(db: db, id: 5002, artist: "B", title: "Two", uuid: "U2")
        try await seedPlaylist(db: db, id: 5010, name: "PL", uuid: "PL-U")

        // Snapshot: U1, U2
        let snapshotEntries: [PlaylistIngestService.SnapshotEntry] = [
            .init(uuid: "U1", path: "A/Album/One.m4a"),
            .init(uuid: "U2", path: "B/Album/Two.m4a")
        ]
        try await service.writeSnapshot(profileId: 1, playlistId: 5010, playlistUuid: "PL-U", entries: snapshotEntries)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-reorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("PL.m3u8")
        // Incoming: U2, U1 (swapped order)
        try writeM3U8(to: fileURL, content: """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-U
        #EXTINF:200,B - Two
        #EXTMLM:U2
        B/Album/Two.m4a
        #EXTINF:200,A - One
        #EXTMLM:U1
        A/Album/One.m4a
        """)

        let preview = try await service.preview(url: fileURL, profileId: 1)
        #expect(preview.added.isEmpty)
        #expect(preview.removed.isEmpty)
        #expect(preview.reordered.count == 2)
    }

    @Test func diffFirstImportNoSnapshotAllAdditions() async throws {
        let (db, service, _, _) = try makeService()

        try await seedTrack(db: db, id: 6001, artist: "A", title: "One", uuid: "U1")
        try await seedTrack(db: db, id: 6002, artist: "B", title: "Two", uuid: "U2")
        try await seedPlaylist(db: db, id: 6010, name: "New PL", uuid: "PL-U")

        // No snapshot written — first import

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-first-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("New PL.m3u8")
        try writeM3U8(to: fileURL, content: """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-U
        #EXTINF:200,A - One
        #EXTMLM:U1
        A/Album/One.m4a
        #EXTINF:200,B - Two
        #EXTMLM:U2
        B/Album/Two.m4a
        """)

        let preview = try await service.preview(url: fileURL, profileId: 1)
        // No snapshot → all entries are additions
        #expect(preview.added.count == 2)
        #expect(preview.removed.isEmpty)
    }

    // MARK: - Apply Tests

    @Test func applyAddsTracksToPlaylist() async throws {
        let (db, service, trackRepo, playlistRepo) = try makeService()

        try await seedTrack(db: db, id: 7001, artist: "A", title: "One", uuid: "U1")
        try await seedTrack(db: db, id: 7002, artist: "B", title: "Two", uuid: "U2")
        try await seedPlaylist(db: db, id: 7010, name: "PL", uuid: "PL-U")

        // Snapshot has only track 1
        let snapshotEntries: [PlaylistIngestService.SnapshotEntry] = [
            .init(uuid: "U1", path: "A/Album/One.m4a")
        ]
        try await service.writeSnapshot(profileId: 1, playlistId: 7010, playlistUuid: "PL-U", entries: snapshotEntries)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-apply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("PL.m3u8")
        try writeM3U8(to: fileURL, content: """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-U
        #EXTINF:200,A - One
        #EXTMLM:U1
        A/Album/One.m4a
        #EXTINF:200,B - Two
        #EXTMLM:U2
        B/Album/Two.m4a
        """)

        let (playlistId, preview) = try await service.ingest(url: fileURL, profileId: 1)
        #expect(playlistId == 7010)
        #expect(preview.added.count == 1)

        // Verify DB state
        let tracks = try await playlistRepo.fetchTracks(playlistId: 7010)
        #expect(tracks.count == 2)
        #expect(tracks[0].id == 7001)
        #expect(tracks[1].id == 7002)

        // Verify snapshot was replaced
        let snapshot = try await service.readSnapshot(profileId: 1, playlistId: 7010)
        #expect(snapshot?.count == 2)
    }

    @Test func applyRemovesTracksFromPlaylist() async throws {
        let (db, service, _, playlistRepo) = try makeService()

        try await seedTrack(db: db, id: 8001, artist: "A", title: "One", uuid: "U1")
        try await seedTrack(db: db, id: 8002, artist: "B", title: "Two", uuid: "U2")
        try await seedPlaylist(db: db, id: 8010, name: "PL", uuid: "PL-U")

        // Add both tracks to playlist initially
        try await playlistRepo.replaceTrackList(playlistId: 8010, trackIds: [8001, 8002])

        // Snapshot matches current state
        let snapshotEntries: [PlaylistIngestService.SnapshotEntry] = [
            .init(uuid: "U1", path: "A/Album/One.m4a"),
            .init(uuid: "U2", path: "B/Album/Two.m4a")
        ]
        try await service.writeSnapshot(profileId: 1, playlistId: 8010, playlistUuid: "PL-U", entries: snapshotEntries)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-rm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("PL.m3u8")
        // Incoming has only track 1
        try writeM3U8(to: fileURL, content: """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-U
        #EXTINF:200,A - One
        #EXTMLM:U1
        A/Album/One.m4a
        """)

        let (playlistId, _) = try await service.ingest(url: fileURL, profileId: 1)
        #expect(playlistId == 8010)

        let tracks = try await playlistRepo.fetchTracks(playlistId: 8010)
        #expect(tracks.count == 1)
        #expect(tracks[0].id == 8001)
    }

    @Test func applyReordersTracks() async throws {
        let (db, service, _, playlistRepo) = try makeService()

        try await seedTrack(db: db, id: 9001, artist: "A", title: "One", uuid: "U1")
        try await seedTrack(db: db, id: 9002, artist: "B", title: "Two", uuid: "U2")
        try await seedPlaylist(db: db, id: 9010, name: "PL", uuid: "PL-U")

        // Initial order: U1, U2
        try await playlistRepo.replaceTrackList(playlistId: 9010, trackIds: [9001, 9002])

        let snapshotEntries: [PlaylistIngestService.SnapshotEntry] = [
            .init(uuid: "U1", path: "A/Album/One.m4a"),
            .init(uuid: "U2", path: "B/Album/Two.m4a")
        ]
        try await service.writeSnapshot(profileId: 1, playlistId: 9010, playlistUuid: "PL-U", entries: snapshotEntries)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-reord-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("PL.m3u8")
        // Incoming: U2, U1 (reversed)
        try writeM3U8(to: fileURL, content: """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-U
        #EXTINF:200,B - Two
        #EXTMLM:U2
        B/Album/Two.m4a
        #EXTINF:200,A - One
        #EXTMLM:U1
        A/Album/One.m4a
        """)

        let (playlistId, _) = try await service.ingest(url: fileURL, profileId: 1)
        #expect(playlistId == 9010)

        let tracks = try await playlistRepo.fetchTracks(playlistId: 9010)
        #expect(tracks.count == 2)
        // New order: U2 first, U1 second
        #expect(tracks[0].id == 9002)
        #expect(tracks[1].id == 9001)
    }

    // MARK: - Liked.m3u8

    @Test func likedM3U8UsesFindOrCreateLikedPlaylist() async throws {
        let (db, service, _, playlistRepo) = try makeService()

        try await seedTrack(db: db, id: 10001, artist: "A", title: "Liked Song", uuid: "LU1")

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-liked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("Liked.m3u8")
        try writeM3U8(to: fileURL, content: """
        #EXTM3U
        #EXTMLM-PLAYLIST:LIKED-UUID
        #EXTINF:200,A - Liked Song
        #EXTMLM:LU1
        A/Album/Liked Song.m4a
        """)

        let (playlistId, preview) = try await service.ingest(url: fileURL, profileId: 1)

        // Should have created a liked playlist
        let playlist = try await playlistRepo.fetch(id: playlistId)
        #expect(playlist != nil)
        #expect(playlist?.isLiked == 1)
        #expect(preview.added.count == 1)

        let tracks = try await playlistRepo.fetchTracks(playlistId: playlistId)
        #expect(tracks.count == 1)
        #expect(tracks[0].id == 10001)
    }

    // MARK: - Roundtrip Idempotency

    @Test func roundtripExportIngestExportIsIdempotent() async throws {
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

        // Step 2: Ingest the exported file unchanged
        let preview = try await service.preview(url: exportedFile, profileId: 1)
        #expect(preview.isEmpty)

        // Step 3: Re-export should produce identical content
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
