import Testing
import Foundation
import GRDB
@testable import MLM

@Suite("PlaylistIngestViewModelTests")
@MainActor
struct PlaylistIngestViewModelTests {

    // MARK: - Helpers

    private func makeTestEnvironment() throws -> (
        db: DatabaseQueue,
        ingestService: PlaylistIngestService,
        vm: PlaylistIngestViewModel,
        tempDir: URL
    ) {
        let db = try DatabaseManager.inMemory()
        let trackRepo = TrackRepository(database: db)
        let playlistRepo = PlaylistRepository(database: db)
        let ingestService = PlaylistIngestService(
            trackRepository: trackRepo,
            playlistRepository: playlistRepo,
            database: db
        )
        let vm = PlaylistIngestViewModel(ingestService: ingestService)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        return (db, ingestService, vm, tempDir)
    }

    private func seedTrack(
        db: DatabaseQueue,
        id: Int64,
        artist: String,
        title: String,
        uuid: String? = nil
    ) async throws {
        let path = "/music/\(artist)/\(title).m4a"
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, duration, original_path, is_duplicate, mlm_uuid)
                VALUES (?, ?, ?, ?, ?, 'm4a', 200, ?, 0, ?)
                """, arguments: [id, artist, artist, "Album", title, path, uuid])
        }
    }

    private func seedPlaylist(
        db: DatabaseQueue,
        id: Int64,
        name: String,
        uuid: String? = nil
    ) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO playlists (id, name, category, mlm_uuid) VALUES (?, ?, 'regular', ?)
                """, arguments: [id, name, uuid])
        }
    }

    private func seedSyncProfile(db: DatabaseQueue, id: Int64, name: String, outputFolder: String) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles (id, name, output_folder, playlist_path_prefix) VALUES (?, ?, ?, '')
                """, arguments: [id, name, outputFolder])
        }
    }

    private func writeM3U8(to url: URL, content: String) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Preview State Machine Tests

    @Test func loadPreviewPopulatesState() async throws {
        let (db, _, vm, tempDir) = try makeTestEnvironment()

        // Seed a track
        try await seedTrack(db: db, id: 1, artist: "Artist A", title: "Track One", uuid: "UUID-1")

        // Write an m3u8 file
        let m3u8URL = tempDir.appendingPathComponent("TestPlaylist.m3u8")
        try writeM3U8(to: m3u8URL, content: """
        #EXTM3U
        #EXTINF:200,Artist A - Track One
        #EXTMLM:UUID-1
        Artist A/Track One.m4a
        """)

        // Load preview
        await vm.loadPreview(url: m3u8URL, profileId: nil)

        // Verify state
        #expect(vm.preview != nil)
        #expect(vm.sourceFileName == "TestPlaylist.m3u8")
        #expect(vm.errorMessage == nil)
        #expect(vm.preview?.added.count == 1)
        #expect(vm.preview?.targetPlaylistName == "TestPlaylist")
        #expect(vm.preview?.willCreate == true)

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func loadPreviewWithNoMatchesShowsUnresolved() async throws {
        let (_, _, vm, tempDir) = try makeTestEnvironment()

        // Write an m3u8 file with no matching tracks
        let m3u8URL = tempDir.appendingPathComponent("Unknown.m3u8")
        try writeM3U8(to: m3u8URL, content: """
        #EXTM3U
        #EXTINF:200,Unknown Artist - Unknown Track
        Unknown/Track.m4a
        """)

        await vm.loadPreview(url: m3u8URL, profileId: nil)

        #expect(vm.preview != nil)
        #expect(vm.preview?.unresolved.count == 1)
        #expect(vm.preview?.added.isEmpty == true)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func cancelClearsState() async throws {
        let (db, _, vm, tempDir) = try makeTestEnvironment()

        try await seedTrack(db: db, id: 1, artist: "Artist A", title: "Track One", uuid: "UUID-1")

        let m3u8URL = tempDir.appendingPathComponent("Test.m3u8")
        try writeM3U8(to: m3u8URL, content: """
        #EXTM3U
        #EXTINF:200,Artist A - Track One
        #EXTMLM:UUID-1
        Artist A/Track One.m4a
        """)

        await vm.loadPreview(url: m3u8URL, profileId: nil)
        #expect(vm.preview != nil)

        // Cancel
        await vm.cancel()

        #expect(vm.preview == nil)
        #expect(vm.sourceFileName == nil)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func applyCallsEngineAndSetsSuccess() async throws {
        let (db, _, vm, tempDir) = try makeTestEnvironment()

        // Seed track and profile
        try await seedTrack(db: db, id: 1, artist: "Artist A", title: "Track One", uuid: "UUID-1")
        try await seedSyncProfile(db: db, id: 100, name: "TestProfile", outputFolder: tempDir.path)

        let m3u8URL = tempDir.appendingPathComponent("TestPlaylist.m3u8")
        try writeM3U8(to: m3u8URL, content: """
        #EXTM3U
        #EXTINF:200,Artist A - Track One
        #EXTMLM:UUID-1
        Artist A/Track One.m4a
        """)

        // Load preview first
        await vm.loadPreview(url: m3u8URL, profileId: 100)
        #expect(vm.preview != nil)

        // Apply
        let playlistId = await vm.apply(url: m3u8URL, profileId: 100)

        #expect(playlistId != nil)
        #expect(vm.didApplySuccessfully == true)
        #expect(vm.isApplying == false)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func cancelAppliesNothing() async throws {
        let (db, _, vm, tempDir) = try makeTestEnvironment()

        try await seedTrack(db: db, id: 1, artist: "Artist A", title: "Track One", uuid: "UUID-1")

        let m3u8URL = tempDir.appendingPathComponent("Test.m3u8")
        try writeM3U8(to: m3u8URL, content: """
        #EXTM3U
        #EXTINF:200,Artist A - Track One
        #EXTMLM:UUID-1
        Artist A/Track One.m4a
        """)

        await vm.loadPreview(url: m3u8URL, profileId: nil)
        #expect(vm.preview != nil)

        // Cancel — should not apply
        await vm.cancel()

        #expect(vm.preview == nil)
        #expect(vm.didApplySuccessfully == false)

        // Verify no playlist was created
        let playlistCount: Int = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlists") ?? 0
        }
        #expect(playlistCount == 0)

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Delegation Tests (Trigger A)

    @Test func legacyM3UImportViaNewPathProducesExpectedState() async throws {
        // This tests the wiring: legacy m3u import through the engine
        // produces append-only behavior (diff against empty snapshot)
        let (db, ingestService, _, tempDir) = try makeTestEnvironment()

        // Seed tracks
        try await seedTrack(db: db, id: 1, artist: "Artist A", title: "Track One", uuid: "UUID-1")
        try await seedTrack(db: db, id: 2, artist: "Artist B", title: "Track Two", uuid: "UUID-2")
        try await seedPlaylist(db: db, id: 10, name: "MyPlaylist")

        // Write a legacy m3u8 (no EXTMLM headers, just paths)
        let m3u8URL = tempDir.appendingPathComponent("MyPlaylist.m3u8")
        try writeM3U8(to: m3u8URL, content: """
        #EXTM3U
        #EXTINF:200,Artist A - Track One
        Artist A/Track One.m4a
        #EXTINF:180,Artist B - Track Two
        Artist B/Track Two.m4a
        """)

        // Preview with sentinel profileId -1 (no profile context)
        let preview = try await ingestService.preview(url: m3u8URL, profileId: -1)

        // Should resolve to existing playlist by name
        #expect(preview.targetPlaylistId == 10)
        #expect(preview.targetPlaylistName == "MyPlaylist")
        #expect(preview.willCreate == false)

        // With no snapshot, all entries are additions (append behavior)
        #expect(preview.added.count == 2)
        #expect(preview.removed.isEmpty)
        #expect(preview.reordered.isEmpty)

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Profile Scan Tests (Trigger B)

    @Test func profileScanProducesPreviewOnlyForChangedFiles() async throws {
        let (db, ingestService, vm, tempDir) = try makeTestEnvironment()

        // Seed tracks
        try await seedTrack(db: db, id: 1, artist: "Artist A", title: "Track One", uuid: "UUID-1")
        try await seedTrack(db: db, id: 2, artist: "Artist B", title: "Track Two", uuid: "UUID-2")

        // Seed a sync profile with output folder
        let profileId: Int64 = 100
        try await seedSyncProfile(db: db, id: profileId, name: "TestDevice", outputFolder: tempDir.path)

        // Seed a playlist
        try await seedPlaylist(db: db, id: 10, name: "Playlist1", uuid: "PL-UUID-1")

        // Write two m3u8 files:
        // 1. One that matches the snapshot (unchanged)
        // 2. One that differs from the snapshot (changed)

        // First, write and "apply" the unchanged playlist to create a snapshot
        let unchangedURL = tempDir.appendingPathComponent("Playlist1.m3u8")
        try writeM3U8(to: unchangedURL, content: """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-UUID-1
        #EXTINF:200,Artist A - Track One
        #EXTMLM:UUID-1
        Artist A/Track One.m4a
        """)

        // Ingest it to create the snapshot
        _ = try await ingestService.ingest(url: unchangedURL, profileId: profileId)

        // Now write the same content again — this should produce an empty preview
        // (no changes since snapshot matches)

        // Write a second playlist that has changes (different content)
        let changedURL = tempDir.appendingPathComponent("NewPlaylist.m3u8")
        try writeM3U8(to: changedURL, content: """
        #EXTM3U
        #EXTINF:200,Artist B - Track Two
        #EXTMLM:UUID-2
        Artist B/Track Two.m4a
        """)

        // Scan
        let profile = SyncProfile(
            id: profileId,
            name: "TestDevice",
            outputFolder: tempDir.path,
            playlistPathPrefix: "",
            generateM3U8: true,
            transcodeMode: "keep_originals",
            fat32SafePaths: true,
            cleanupRemovedFiles: true
        )

        let results = await vm.scanProfileForChanges(profile: profile)

        // Only the changed file should appear (NewPlaylist.m3u8)
        // Playlist1.m3u8 should NOT appear because it matches the snapshot
        #expect(results.count == 1)
        #expect(results.first?.fileName == "NewPlaylist.m3u8")

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func profileScanWithNoDeviceShowsError() async throws {
        let (_, _, vm, tempDir) = try makeTestEnvironment()

        // Profile pointing to non-existent folder
        let profile = SyncProfile(
            id: 100,
            name: "Disconnected",
            outputFolder: "/nonexistent/path/\(UUID().uuidString)",
            playlistPathPrefix: "",
            generateM3U8: true,
            transcodeMode: "keep_originals",
            fat32SafePaths: true,
            cleanupRemovedFiles: true
        )

        let results = await vm.scanProfileForChanges(profile: profile)

        #expect(results.isEmpty)
        #expect(vm.errorMessage != nil)

        try? FileManager.default.removeItem(at: tempDir)
    }
}
