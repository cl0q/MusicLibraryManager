import Testing
import Foundation
import GRDB
@testable import MLM

/// Contract guard for the path the new tooltip promises: adding individual
/// tracks to a sync profile via the library context menu
/// (right-click -> "Sync to" submenu -> profile).
@Suite("SyncToContextMenuContractTests")
@MainActor
struct SyncToContextMenuContractTests {

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewTests
            .deletingLastPathComponent()   // MLMTests
            .deletingLastPathComponent()   // root
    }

    private func source(_ relativePath: String) throws -> String {
        let url = projectRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeVM() throws -> (DatabaseQueue, SyncViewModel) {
        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxcontract_\(UUID().uuidString)")
        let cache = TranscodeCache(cacheDir: cacheDir)
        let svc = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )
        let vm = SyncViewModel(syncRepository: syncRepo, syncService: svc, notificationCenter: NotificationCenter())
        // W3-SYNC: Add to Sync Profile ▸ goes through ShellEdits (one undo step) on this database.
        let playlists = PlaylistRepository(database: db)
        let undo = UndoCenter(undoManager: UndoManager(), statusBar: StatusBarCenter(), log: { _ in })
        vm.edits = {
            ShellEdits(dependencies: .init(playlists: { playlists }, syncProfiles: { syncRepo }, syncProfileDidChange: { _ in }),
                       undo: undo, window: ShellWindowModels())
        }
        return (db, vm)
    }

    /// W2-A: `Sync to ▸` is `Add to Sync Profile ▸` (CM-SUB-SYNC, UC-COPY-07) in the one track menu.
    @Test func syncToSubmenuStillExistsInTrackContextMenu() throws {
        let src = try source("MLM/Views/TrackList/TrackMenu.swift")
        #expect(src.contains("Menu(\"Add to Sync Profile\")"))
        #expect(src.contains("actions.addToSyncProfile(profile, rows)"))
        #expect(src.contains("New Sync Profile…"))
        #expect(!src.contains("Sync to"))
    }

    @Test func libraryTableWiresSyncToAction() throws {
        let actions = try source("MLM/Views/TrackList/TrackListActions.swift")
        // W3-SYNC: routed through the undoable ShellEdits path; nothing selects the profile.
        #expect(actions.contains("TrackCommandActions.addToSyncProfile(profile, tracks: rows.map(\\.track), shell: shell)"))
        #expect(!actions.contains("selectedProfile"))
        // The Track menu reaches the same action through the published selection.
        #expect(try source("MLM/Views/TrackList/TrackListTable.swift").contains("addToSyncProfile: { profile, ids in"))
    }

    @Test func addTracksLinksTrackToProfile() async throws {
        let (db, vm) = try makeVM()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix) VALUES ('P', '/tmp', '')")
            try db.execute(sql: """
                INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                VALUES ('Artist', 'Artist', 'Album', 'Song', 'flac', '/tmp/song.flac')
            """)
        }
        let profile = try await db.read { db in try SyncProfile.fetchOne(db)! }
        let trackId: Int64 = try await db.read { db in
            (try Row.fetchOne(db, sql: "SELECT id FROM tracks"))?["id"] ?? -1
        }
        // Simulates Add to Sync Profile ▸ P.
        await vm.addTracks([trackId], to: profile)

        let count: Int = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_profile_tracks WHERE profile_id = ?",
                             arguments: [profile.id!])!
        }
        #expect(count == 1)
    }

    @Test func addTracksIsIdempotent() async throws {
        let (db, vm) = try makeVM()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix) VALUES ('P', '/tmp', '')")
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
        await vm.addTracks([trackId], to: profile)

        let count: Int = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_profile_tracks WHERE profile_id = ?",
                             arguments: [profile.id!])!
        }
        #expect(count == 1)
    }

    @Test func profileTracksReloadReflectsContextAdd() async throws {
        let (db, vm) = try makeVM()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix) VALUES ('P', '/tmp', '')")
            try db.execute(sql: """
                INSERT INTO tracks (artist, album_artist, album, title, format, original_path)
                VALUES ('Artist', 'Artist', 'Album', 'Context Song', 'flac', '/tmp/song.flac')
            """)
        }
        let profile = try await db.read { db in try SyncProfile.fetchOne(db)! }
        let trackId: Int64 = try await db.read { db in
            (try Row.fetchOne(db, sql: "SELECT id FROM tracks"))?["id"] ?? -1
        }
        await vm.addTracks([trackId], to: profile)
        await vm.loadContent(profile.id!)
        #expect(vm.contents[profile.id!]?.tracks.contains { $0.id == trackId } == true)
    }
}
