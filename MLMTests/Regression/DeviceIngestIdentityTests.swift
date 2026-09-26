import Foundation
import GRDB
import Testing
@testable import MLM

@Suite("LOGIC-007 device ingest identity")
@MainActor
struct DeviceIngestIdentityTests {

    @Test func concurrentAppliesRemoveOnlyTheirOwnPreviews() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let (db, viewModel) = try makeViewModel()
        let profile = try await seedProfile(db: db, outputFolder: directory.path)
        let firstURL = directory.appendingPathComponent("first.m3u8")
        let secondURL = directory.appendingPathComponent("second.m3u8")
        try await seedTrack(db: db, id: 1, uuid: "TRACK-ONE", title: "One")
        try await seedTrack(db: db, id: 2, uuid: "TRACK-TWO", title: "Two")
        try writePlaylist(to: firstURL, name: "First", trackUUID: "TRACK-ONE", title: "One")
        try writePlaylist(to: secondURL, name: "Second", trackUUID: "TRACK-TWO", title: "Two")

        await viewModel.scanDeviceForPlaylistChanges(profile: profile)
        #expect(Set(viewModel.deviceIngestPreviews.map(\.fileName)) == ["first.m3u8", "second.m3u8"])

        // PlaylistIngestService is concrete/final, so the ViewModel has no
        // controllable completion gate. Starting the first task, yielding, and
        // then starting the second reproduces the real re-entrant apply path.
        let firstApply = Task { @MainActor in
            await viewModel.applyDeviceIngest(
                fileName: "first.m3u8",
                profile: profile,
                fileURL: firstURL
            )
        }
        await Task.yield()
        let secondApply = Task { @MainActor in
            await viewModel.applyDeviceIngest(
                fileName: "second.m3u8",
                profile: profile,
                fileURL: secondURL
            )
        }

        #expect(await firstApply.value != nil)
        #expect(await secondApply.value != nil)
        #expect(viewModel.deviceIngestPreviews.isEmpty)
        #expect(viewModel.deviceScanError == nil)
    }

    @Test func reverseApplicationRemovesExactlyTheAppliedNames() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let (db, viewModel) = try makeViewModel()
        let profile = try await seedProfile(db: db, outputFolder: directory.path)
        let playlists = [
            ("first.m3u8", "First", "TRACK-ONE", "One", Int64(1)),
            ("second.m3u8", "Second", "TRACK-TWO", "Two", Int64(2)),
            ("third.m3u8", "Third", "TRACK-THREE", "Three", Int64(3)),
        ]
        for playlist in playlists {
            try await seedTrack(db: db, id: playlist.4, uuid: playlist.2, title: playlist.3)
            try writePlaylist(
                to: directory.appendingPathComponent(playlist.0),
                name: playlist.1,
                trackUUID: playlist.2,
                title: playlist.3
            )
        }

        await viewModel.scanDeviceForPlaylistChanges(profile: profile)
        #expect(viewModel.deviceIngestPreviews.count == playlists.count)

        for playlist in playlists.reversed() {
            let playlistURL = directory.appendingPathComponent(playlist.0)
            #expect(await viewModel.applyDeviceIngest(
                fileName: playlist.0,
                profile: profile,
                fileURL: playlistURL
            ) != nil)
            #expect(!viewModel.deviceIngestPreviews.contains(where: { $0.fileName == playlist.0 }))
        }

        #expect(viewModel.deviceIngestPreviews.isEmpty)
    }

    private func makeViewModel() throws -> (DatabaseQueue, SyncViewModel) {
        let db = try DatabaseManager.inMemory()
        let syncRepository = SyncRepository(database: db)
        let trackRepository = TrackRepository(database: db)
        let playlistRepository = PlaylistRepository(database: db)
        let configRepository = ConfigRepository(database: db)
        let syncService = SyncService(
            trackRepository: trackRepository,
            syncRepository: syncRepository,
            configRepository: configRepository,
            transcodeCache: TranscodeCache(cacheDir: FileManager.default.temporaryDirectory)
        )
        let ingestService = PlaylistIngestService(
            trackRepository: trackRepository,
            playlistRepository: playlistRepository,
            database: db
        )
        return (
            db,
            SyncViewModel(
                syncRepository: syncRepository,
                syncService: syncService,
                ingestService: ingestService
            )
        )
    }

    private func seedProfile(db: DatabaseQueue, outputFolder: String) async throws -> SyncProfile {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix)
                VALUES ('Device', ?, '')
                """, arguments: [outputFolder])
        }
        return try await db.read { db in
            try SyncProfile.fetchOne(db)!
        }
    }

    private func seedTrack(db: DatabaseQueue, id: Int64, uuid: String, title: String) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (
                    id, artist, album_artist, album, title, format,
                    duration, original_path, is_duplicate, mlm_uuid
                ) VALUES (?, 'Artist', 'Artist', 'Album', ?, 'm4a', 200, ?, 0, ?)
                """, arguments: [id, title, "/music/\(title).m4a", uuid])
        }
    }

    private func writePlaylist(to url: URL, name: String, trackUUID: String, title: String) throws {
        try """
            #EXTM3U
            #EXTMLM-PLAYLIST:PLAYLIST-\(name.uppercased())
            #EXTINF:200,Artist - \(title)
            #EXTMLM:\(trackUUID)
            Artist/Album/\(title).m4a
            """.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceIngestIdentityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
