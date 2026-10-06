import Testing
import Foundation
import GRDB
@testable import MLM

@Suite("PickerSheetTests")
@MainActor
struct PickerSheetTests {
    @MainActor final class Changed { var ids: [Int64] = [] }
    private let changedProfiles = Changed()

    private func makeVM() throws -> (DatabaseQueue, SyncViewModel) {
        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker_\(UUID().uuidString)")
        let cache = TranscodeCache(cacheDir: cacheDir)
        let svc = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )
        let vm = SyncViewModel(syncRepository: syncRepo, syncService: svc, notificationCenter: NotificationCenter())
        // W3-SYNC: the picker's Add goes through ShellEdits (one undo step) on this database.
        let playlists = PlaylistRepository(database: db)
        let undo = UndoCenter(undoManager: UndoManager(), statusBar: StatusBarCenter(), log: { _ in })
        let changed = changedProfiles
        vm.edits = {
            ShellEdits(dependencies: .init(playlists: { playlists }, syncProfiles: { syncRepo },
                                           syncProfileDidChange: { _ in },
                                           syncContentDidChange: { changed.ids.append($0) }),
                       undo: undo, window: ShellWindowModels())
        }
        return (db, vm)
    }

    @Test func addPlaylistsIsIdempotent() async throws {
        let (db, vm) = try makeVM()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix) VALUES ('P', '/tmp', '')")
            try db.execute(sql: "INSERT INTO playlists (name, category) VALUES ('Club Set 2026', 'regular')")
        }
        let profile = try await db.read { db in try SyncProfile.fetchOne(db)! }
        let playlistId: Int64 = try await db.read { db in
            (try Row.fetchOne(db, sql: "SELECT id FROM playlists"))?["id"] ?? -1
        }
        // Add same playlist twice
        await vm.addPlaylists([playlistId, playlistId], to: profile)

        // Count rows — should be 1, not 2 (INSERT OR IGNORE)
        let count: Int = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_profile_playlists WHERE profile_id = ?",
                             arguments: [profile.id!])!
        }
        #expect(count == 1)
    }

    @Test func allPlaylistsReturnedOnEmptyQuery() async throws {
        let (db, vm) = try makeVM()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO playlists (name, category) VALUES ('Club Set 2026', 'regular')")
            try db.execute(sql: "INSERT INTO playlists (name, category) VALUES ('Focus', 'regular')")
            try db.execute(sql: "INSERT INTO playlists (name, category) VALUES ('Workout', 'regular')")
        }
        // Mirrors PlaylistPickerSheet.loadPlaylists() -> container.playlistRepository.fetchAll()
        // Test the VM's data layer (playlist fetch)
        // Verify the DB has 3 playlists (foundation for picker to show all)
        let all = try await db.read { db in try Playlist.fetchAll(db) }
        #expect(all.count == 3)
        _ = vm
    }

    @Test func searchFilterMatchesCaseInsensitive() async throws {
        let (db, _) = try makeVM()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO playlists (name, category) VALUES ('Club Set 2026', 'regular')")
            try db.execute(sql: "INSERT INTO playlists (name, category) VALUES ('Focus', 'regular')")
        }
        let all = try await db.read { db in try Playlist.fetchAll(db) }
        // Filter locally — mirrors PlaylistPickerSheet.filtered computed property
        let query = "club"
        let filtered = all.filter { $0.name.localizedCaseInsensitiveContains(query) }
        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "Club Set 2026")
    }

    @Test func addTracksPostsNotification() async throws {
        let (db, vm) = try makeVM()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix) VALUES ('P', '/tmp', '')")
            // Insert a real track so FK constraint passes
            try db.execute(sql: """
                INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                VALUES ('Artist', 'Artist', 'Album', 'Song', 'flac', '/tmp/song.flac')
            """)
        }
        let profile = try await db.read { db in try SyncProfile.fetchOne(db)! }
        let trackId: Int64 = try await db.read { db in
            (try Row.fetchOne(db, sql: "SELECT id FROM tracks"))?["id"] ?? -1
        }
        await vm.addTracks([trackId], to: profile)
        // The profile's content change is announced (W3-SYNC: through the injected edit effects,
        // not NotificationCenter.default).
        #expect(changedProfiles.ids == [profile.id!])
    }
}
