import Foundation
import GRDB
import Testing
@testable import MLM

/// The shell's undoable edits on a temporary database (W2-F adoptions): each action, its
/// Undo restoring the exact earlier rows / order / names, its Redo re-applying it, and the
/// status-bar and Edit-menu wording.
@Suite("Shell undoable edits")
@MainActor
struct ShellEditsUndoTests {
    @MainActor
    struct Env {
        let db: DatabaseQueue
        let playlists: PlaylistRepository
        let sync: SyncRepository
        let manager: UndoManager
        let status: StatusBarCenter
        let undo: UndoCenter
        let navigation: NavigationModel
        let sidebar: SidebarModel
        let edits: ShellEdits
    }

    private let sleeper = ManualSleeper()

    private func makeEnv() throws -> Env {
        let db = try DatabaseManager.inMemory()
        let playlists = PlaylistRepository(database: db)
        let sync = SyncRepository(database: db)
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = self.sleeper
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let navigation = NavigationModel()
        let defaults = UserDefaults(suiteName: "ShellEditsUndoTests-\(UUID().uuidString)")!
        let sidebar = SidebarModel(defaults: defaults)
        let edits = ShellEdits(
            dependencies: ShellEdits.Dependencies(
                playlists: { playlists },
                syncProfiles: { sync },
                syncProfileDidChange: { _ in }
            ),
            undo: undo,
            statusBar: status,
            navigation: navigation,
            sidebar: sidebar
        )
        return Env(db: db, playlists: playlists, sync: sync, manager: manager, status: status,
                   undo: undo, navigation: navigation, sidebar: sidebar, edits: edits)
    }

    private func seedTracks(_ env: Env, _ ids: [Int64]) async throws {
        try await env.db.write { db in
            for id in ids {
                try db.execute(sql: """
                    INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, date_added)
                    VALUES (?, 'A', 'A', 'Album', 'Track \(id)', 'mp3', '/tmp/\(id).mp3', '2025-01-01T00:00:00Z')
                """, arguments: [id])
            }
        }
    }

    /// Each row's values, in column order (`Row` itself isn't Sendable).
    private func rows(_ env: Env, _ playlistID: Int64) async throws -> [[DatabaseValue]] {
        try await env.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, track_id, position, added_at FROM playlist_tracks WHERE playlist_id = ?
                ORDER BY position, added_at, id
            """, arguments: [playlistID]).map { Array($0.databaseValues) }
        }
    }

    private func undo(_ env: Env) async {
        env.manager.undo()
        await env.undo.waitUntilIdle()
    }

    private func redo(_ env: Env) async {
        env.manager.redo()
        await env.undo.waitUntilIdle()
    }

    // MARK: New Playlist

    @Test func newPlaylistIsOneStepAndRedoBringsBackTheSamePlaylist() async throws {
        let env = try makeEnv()
        let created = try #require(await env.edits.newPlaylist())
        let id = try #require(created.id)
        #expect(created.name == "Untitled Playlist")
        #expect(env.status.message?.text == "Created “Untitled Playlist”")
        #expect(env.manager.undoMenuItemTitle == "Undo New Playlist")
        #expect(env.navigation.selection == .playlist(id))
        #expect(env.sidebar.takeRenameRequest()?.id == id)

        await undo(env)
        #expect(try await env.playlists.fetch(id: id) == nil)
        #expect(env.sidebar.playlists.isEmpty)
        #expect(env.navigation.selection != .playlist(id))

        await redo(env)
        #expect(try await env.playlists.fetch(id: id)?.name == "Untitled Playlist")
        #expect(env.sidebar.playlists.map(\.id) == [id])
    }

    @Test func newPlaylistIsNumberedWhenTheNameIsTaken() async throws {
        let env = try makeEnv()
        _ = try await env.playlists.create(name: "Untitled Playlist")
        let created = try #require(await env.edits.newPlaylist())
        #expect(created.name == "Untitled Playlist 2")
    }

    // MARK: New Playlist from Selection

    @Test func newPlaylistFromSelectionKeepsTheOrderAndUndoesInOneStep() async throws {
        let env = try makeEnv()
        try await seedTracks(env, [1, 2, 3])
        let created = try #require(await env.edits.newPlaylist(fromTrackIDs: [3, 1, 2]))
        let id = try #require(created.id)
        #expect(env.status.message?.text == "Created “Untitled Playlist” with 3 tracks")
        #expect(env.manager.undoMenuItemTitle == "Undo New Playlist from Selection")
        #expect(env.navigation.selection != .playlist(id)) // doesn't navigate
        #expect(env.sidebar.renameRequest == id)
        let before = try await rows(env, id)

        await undo(env)
        #expect(try await env.playlists.fetch(id: id) == nil)
        #expect(try await rows(env, id).isEmpty)
        #expect(!env.manager.canUndo) // playlist and tracks were one step

        await redo(env)
        #expect(try await rows(env, id) == before)
        #expect(try await env.playlists.fetchTracks(playlistId: id).compactMap(\.id) == [3, 1, 2])
    }

    // MARK: Add to Playlist

    @Test func addToPlaylistUndoRemovesOnlyTheRowsItAdded() async throws {
        let env = try makeEnv()
        try await seedTracks(env, [1, 2, 3])
        let id = try await env.playlists.create(name: "Warm-up").id!
        try await env.playlists.addTrack(playlistId: id, trackId: 2, position: "a0")
        await env.sidebar.reloadPlaylists(env.playlists)
        let before = try await rows(env, id)

        await env.edits.addTracks([1, 2, 3], toPlaylist: id)
        #expect(env.status.message?.text == "Added 2 tracks to “Warm-up” · 1 was already in it")
        #expect(env.status.message?.actions.map(\.title) == ["Undo"])
        #expect(env.manager.undoMenuItemTitle == "Undo Add to “Warm-up”")
        let after = try await rows(env, id)

        await undo(env)
        #expect(try await rows(env, id) == before)

        await redo(env)
        #expect(try await rows(env, id) == after)

        await undo(env)
        #expect(try await rows(env, id) == before)
    }

    @Test func addingTracksThatAreAllThereAlreadyIsNoStep() async throws {
        let env = try makeEnv()
        try await seedTracks(env, [1, 2])
        let id = try await env.playlists.create(name: "Warm-up").id!
        try await env.playlists.appendTracks(playlistId: id, trackIds: [1, 2])
        await env.edits.addTracks([2, 1], toPlaylist: id)
        #expect(env.status.message?.text == "All 2 tracks were already in “Warm-up”")
        #expect(env.status.message?.actions.isEmpty == true)
        #expect(!env.manager.canUndo)
    }

    @Test func addMessagesFollowTheStatusBarPatterns() {
        #expect(ShellEdits.addedMessage(added: 3, alreadyPresent: 0, playlist: "Warm-up") == "Added 3 tracks to “Warm-up”")
        #expect(ShellEdits.addedMessage(added: 1, alreadyPresent: 0, playlist: "Warm-up") == "Added 1 track to “Warm-up”")
        #expect(ShellEdits.addedMessage(added: 2, alreadyPresent: 1, playlist: "Warm-up") == "Added 2 tracks to “Warm-up” · 1 was already in it")
        #expect(ShellEdits.addedMessage(added: 1, alreadyPresent: 2, playlist: "Warm-up") == "Added 1 track to “Warm-up” · 2 were already in it")
        #expect(ShellEdits.alreadyPresentMessage(count: 1, playlist: "Warm-up") == "The track was already in “Warm-up”")
    }

    // MARK: Rename

    @Test func renamingAPlaylistUndoesAndRedoesTheName() async throws {
        let env = try makeEnv()
        let id = try await env.playlists.create(name: "Untitled Playlist").id!
        try await env.edits.renamePlaylist(id, from: "Untitled Playlist", to: "Warm-up")
        #expect(env.status.message?.text == "Renamed “Untitled Playlist” to “Warm-up”")
        #expect(env.manager.undoMenuItemTitle == "Undo Rename Playlist")

        await undo(env)
        #expect(try await env.playlists.fetch(id: id)?.name == "Untitled Playlist")
        #expect(env.sidebar.playlistName(id) == "Untitled Playlist")
        await redo(env)
        #expect(try await env.playlists.fetch(id: id)?.name == "Warm-up")
    }

    @Test func renamingToATakenNameFailsUnderTheFieldWithoutAStep() async throws {
        let env = try makeEnv()
        let id = try await env.playlists.create(name: "Sets").id!
        _ = try await env.playlists.create(name: "Warm-up")
        await #expect(throws: NameTaken.self) {
            try await env.edits.renamePlaylist(id, from: "Sets", to: "warm-up")
        }
        #expect(!env.manager.canUndo)
        #expect(env.status.message == nil) // the field says it (UC-SHEET-17)
        #expect(ShellEdits.renameFailure(NameTaken(kind: "playlist", name: "Warm-up"), kind: "playlist")
            == "Couldn’t rename the playlist — another playlist is called “Warm-up”.")
    }

    @Test func renamingASyncProfileUndoesAndRedoesTheName() async throws {
        let env = try makeEnv()
        let profile = try await env.sync.create(name: "iPod Classic", outputFolder: "/tmp/ipod")
        let id = try #require(profile.id)
        try await env.edits.renameSyncProfile(id, from: "iPod Classic", to: "iPod Video")
        #expect(env.status.message?.text == "Renamed to “iPod Video”")
        #expect(env.manager.undoMenuItemTitle == "Undo Rename Sync Profile")
        await undo(env)
        #expect(try await env.sync.fetch(id: id)?.name == "iPod Classic")
        await redo(env)
        #expect(try await env.sync.fetch(id: id)?.name == "iPod Video")
    }

    @Test func undoingARenameOfAProfileDeletedMeanwhileSaysItIsGone() async throws {
        let env = try makeEnv()
        let id = try await env.sync.create(name: "iPod Classic", outputFolder: "/tmp/ipod").id!
        try await env.edits.renameSyncProfile(id, from: "iPod Classic", to: "iPod Video")
        try await env.sync.delete(id: id) // confirmed, not undoable (UC-UNDO-03)
        await undo(env)
        #expect(env.status.message?.text == "Couldn’t undo Rename Sync Profile — “iPod Video” no longer exists")
        #expect(!env.manager.canRedo)
    }

    // MARK: Delete Playlist

    @Test func deletePlaylistIsRestorableWithEveryRowAndRedoDeletesAgain() async throws {
        let env = try makeEnv()
        try await seedTracks(env, [1, 2])
        let id = try await env.playlists.create(name: "Warm-up").id!
        try await env.playlists.appendTracks(playlistId: id, trackIds: [2, 1])
        let profile = try await env.sync.create(name: "iPod Classic", outputFolder: "/tmp/ipod")
        try await env.sync.addPlaylist(profileId: profile.id!, playlistId: id)
        await env.sidebar.reloadPlaylists(env.playlists)
        env.navigation.select(.playlist(id))
        let before = try await rows(env, id)
        let playlistBefore = try await env.playlists.fetch(id: id)

        await env.edits.deletePlaylist(id, name: "Warm-up")
        #expect(env.status.message?.text == "Deleted “Warm-up”")
        #expect(env.manager.undoMenuItemTitle == "Undo Delete “Warm-up”")
        #expect(try await env.playlists.fetch(id: id) == nil)
        #expect(env.navigation.selection == .allPlaylists)
        #expect(try await env.sync.fetchProfilePlaylists(profileId: profile.id!).isEmpty)

        await undo(env)
        #expect(try await env.playlists.fetch(id: id) == playlistBefore)
        #expect(try await rows(env, id) == before)
        #expect(try await env.sync.fetchProfilePlaylists(profileId: profile.id!).map(\.id) == [id])
        #expect(env.sidebar.playlists.map(\.id) == [id])

        await redo(env)
        #expect(try await env.playlists.fetch(id: id) == nil)
        await undo(env)
        #expect(try await rows(env, id) == before)
    }

    @Test func theDeleteConfirmationStatesWhatGoesWhatStaysAndThatUndoWorks() {
        let none = PlaylistDeletionConfirmation.make(name: "Warm-up", impact: .init(trackCount: 44, syncProfileNames: []))
        #expect(none.title == "Delete “Warm-up”?")
        #expect(none.message == "The playlist is removed from the sidebar. Its 44 tracks and their files stay in the library. You can undo this until you quit MLM.")
        let one = PlaylistDeletionConfirmation.make(name: "Warm-up", impact: .init(trackCount: 44, syncProfileNames: ["iPod Classic"]))
        #expect(one.message == "The playlist is removed from the sidebar and from the sync profile “iPod Classic”. Its 44 tracks and their files stay in the library. You can undo this until you quit MLM.")
        let two = PlaylistDeletionConfirmation.make(name: "X", impact: .init(trackCount: 1, syncProfileNames: ["A", "B"]))
        #expect(two.message == "The playlist is removed from the sidebar and from the sync profiles “A” and “B”. Its track and its file stay in the library. You can undo this until you quit MLM.")
        let many = PlaylistDeletionConfirmation.make(name: "X", impact: .init(trackCount: 0, syncProfileNames: ["A", "B", "C"]))
        #expect(many.message == "The playlist is removed from the sidebar and from 3 sync profiles. It has no tracks. You can undo this until you quit MLM.")
        #expect(PlaylistDeletionConfirmation.confirmTitle == "Delete Playlist")
    }

    @Test func aRestoreThatCouldNotBeExactSaysWhy() {
        let playlist = Playlist.createNative(name: "Warm-up 2")
        let renamed = PlaylistRestoreResult(playlist: playlist, droppedTrackCount: 0, wasRenamed: true)
        #expect(PlaylistEffects.restoreNote(original: "Warm-up", result: renamed) == "Restored “Warm-up 2” — “Warm-up” was taken")
        let exact = PlaylistRestoreResult(playlist: Playlist.createNative(name: "Warm-up"), droppedTrackCount: 0, wasRenamed: false)
        #expect(PlaylistEffects.restoreNote(original: "Warm-up", result: exact) == nil)
        let dropped = PlaylistRestoreResult(playlist: Playlist.createNative(name: "Warm-up"), droppedTrackCount: 2, wasRenamed: false)
        #expect(PlaylistEffects.restoreNote(original: "Warm-up", result: dropped) == "Restored “Warm-up” — 2 of its tracks are no longer in the library")
    }

    @Test func aFailedDeleteIsReportedInTheStatusBar() async throws {
        let env = try makeEnv()
        await env.edits.deletePlaylist(999, name: "Ghost")
        #expect(env.status.message?.text == "Couldn’t delete “Ghost” — the playlist no longer exists")
        #expect(!env.manager.canUndo)
    }
}
