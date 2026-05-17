import Testing
import Foundation
import GRDB
@testable import MLM

@Suite("SyncViewModelTests")
@MainActor
struct SyncViewModelTests {

    // MARK: - Setup

    /// Correct init for test doubles:
    /// - TrackRepository.init(database: any DatabaseWriter) — single param
    /// - TranscodeCache.init(cacheDir: URL) — single param (NOT database:libraryRoot:)
    /// - SyncService.init(trackRepository:syncRepository:configRepository:transcodeCache:) — 4 params
    private func makeViewModel() throws -> (DatabaseQueue, SyncRepository, SyncViewModel) {
        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_cache_\(UUID().uuidString)")
        let transcodeCache = TranscodeCache(cacheDir: cacheDir)
        let syncService = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: transcodeCache
        )
        let vm = SyncViewModel(syncRepository: syncRepo, syncService: syncService)
        return (db, syncRepo, vm)
    }

    // MARK: - Tests

    @Test func addPlaylistsPostsNotification() async throws {
        let (db, _, vm) = try makeViewModel()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix) VALUES ('T', '/tmp', '')")
            try db.execute(sql: "INSERT INTO playlists (name, category) VALUES ('PL', 'regular')")
        }
        let profile = try await db.read { db in try SyncProfile.fetchOne(db)! }
        vm.selectedProfile = profile

        var received = false
        let token = NotificationCenter.default.addObserver(
            forName: .syncProfileDidChange, object: nil, queue: nil
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(token) }

        let playlistId: Int64 = try await db.read { db in
            (try Row.fetchOne(db, sql: "SELECT id FROM playlists"))?["id"] ?? -1
        }
        await vm.addPlaylists([playlistId])
        #expect(received)
    }

    @Test func addTracksPostsNotification() async throws {
        let (db, _, vm) = try makeViewModel()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix) VALUES ('T', '/tmp', '')")
            // Insert a real track so FK constraint passes
            try db.execute(sql: """
                INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                VALUES ('Artist', 'Artist', 'Album', 'Song', 'flac', '/tmp/song.flac')
            """)
        }
        let profile = try await db.read { db in try SyncProfile.fetchOne(db)! }
        vm.selectedProfile = profile

        var received = false
        let token = NotificationCenter.default.addObserver(
            forName: .syncProfileDidChange, object: nil, queue: nil
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(token) }

        let trackId: Int64 = try await db.read { db in
            (try Row.fetchOne(db, sql: "SELECT id FROM tracks"))?["id"] ?? -1
        }
        await vm.addTracks([trackId])
        #expect(received)
    }

    @Test func removePlaylistsPostsNotification() async throws {
        let (db, _, vm) = try makeViewModel()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix) VALUES ('T', '/tmp', '')")
        }
        let profile = try await db.read { db in try SyncProfile.fetchOne(db)! }
        vm.selectedProfile = profile

        var received = false
        let token = NotificationCenter.default.addObserver(
            forName: .syncProfileDidChange, object: nil, queue: nil
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(token) }

        await vm.removePlaylists([1])
        #expect(received)
    }

    @Test func updateProfileSettingsPostsNotification() async throws {
        let (db, _, vm) = try makeViewModel()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix) VALUES ('T', '/tmp', '')")
        }
        let profile = try await db.read { db in try SyncProfile.fetchOne(db)! }
        vm.selectedProfile = profile

        var received = false
        let token = NotificationCenter.default.addObserver(
            forName: .syncProfileDidChange, object: nil, queue: nil
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(token) }

        await vm.updateProfileSettings(generateM3U8: true)
        #expect(received)

        let updated = try await db.read { db in try SyncProfile.fetchOne(db) }
        #expect(updated?.generateM3U8 == true)
    }

    @Test func cancelSyncDoesNotCrash() async throws {
        let (_, _, vm) = try makeViewModel()
        // cancelSync() should not crash even when no sync is running
        vm.cancelSync()
        // No crash = success
    }

    @Test func createProfileWithTogglesPersistsDefaults() async throws {
        let (db, _, vm) = try makeViewModel()
        await vm.createProfile(
            name: "TestPod",
            outputFolder: "/tmp",
            generateM3U8: true,
            transcodeMode: "aac_248",
            fat32SafePaths: true,
            cleanupRemovedFiles: true
        )
        let profiles = try await db.read { db in try SyncProfile.fetchAll(db) }
        let created = profiles.first { $0.name == "TestPod" }
        #expect(created != nil)
        #expect(created?.generateM3U8 == true)
        #expect(created?.transcodeMode == "aac_248")
        #expect(created?.fat32SafePaths == true)
        #expect(created?.cleanupRemovedFiles == true)
    }
}
