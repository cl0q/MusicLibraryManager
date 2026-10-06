import Testing
import Foundation
import GRDB
@testable import MLM

@Suite("SyncContextMenuTests")
@MainActor
struct SyncContextMenuTests {

    private func makeVM() throws -> (DatabaseQueue, SyncViewModel) {
        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx_\(UUID().uuidString)")
        let cache = TranscodeCache(cacheDir: cacheDir)
        let svc = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )
        let vm = SyncViewModel(syncRepository: syncRepo, syncService: svc, notificationCenter: NotificationCenter())
        // W3-SYNC: content edits go through ShellEdits (undoable) on this test database.
        let playlists = PlaylistRepository(database: db)
        let undo = UndoCenter(undoManager: UndoManager(), statusBar: StatusBarCenter(), log: { _ in })
        vm.edits = {
            ShellEdits(dependencies: .init(playlists: { playlists }, syncProfiles: { syncRepo }, syncProfileDidChange: { _ in }),
                       undo: undo, window: ShellWindowModels())
        }
        return (db, vm)
    }

    @Test func profilesEmptyInitially() async throws {
        let (_, vm) = try makeVM()
        await vm.loadProfiles()
        #expect(vm.profiles.isEmpty)
    }

    @Test func profilesPopulatedAfterCreate() async throws {
        let (db, vm) = try makeVM()
        _ = await vm.createProfile(name: "iPod Sync", outputFolder: "/tmp", preset: .plainFolder)
        await vm.loadProfiles()
        #expect(vm.profiles.count == 1)
        #expect(vm.profiles.first?.name == "iPod Sync")
        _ = db
    }

    @Test func addPlaylistToProfileViaContextMenuAction() async throws {
        let (db, vm) = try makeVM()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix) VALUES ('P', '/tmp', '')")
            try db.execute(sql: "INSERT INTO playlists (name, category) VALUES ('MyPL', 'regular')")
        }
        let profile = try await db.read { db in try SyncProfile.fetchOne(db)! }
        let playlistId: Int64 = try await db.read { db in
            (try Row.fetchOne(db, sql: "SELECT id FROM playlists"))?["id"] ?? -1
        }
        // Add to Sync Profile ▸ (W3-SYNC: names its profile; nothing is "selected").
        await vm.addPlaylists([playlistId], to: profile)

        let count: Int = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_profile_playlists WHERE profile_id = ?",
                             arguments: [profile.id!])!
        }
        #expect(count == 1)
    }

    @Test func syncProfilesHaveNewToggleColumnDefaults() async throws {
        let (db, vm) = try makeVM()
        _ = await vm.createProfile(name: "Folder Sync", outputFolder: "/tmp", preset: .plainFolder)
        let profiles = try await db.read { db in try SyncProfile.fetchAll(db) }
        let p = profiles.first!

        // D-01 defaults
        #expect(p.generateM3U8 == false)
        #expect(p.transcodeMode == "keep_originals")
        #expect(p.fat32SafePaths == true)
        #expect(p.cleanupRemovedFiles == true)
        _ = db
    }
}
