import Foundation
import GRDB
import Testing
@testable import MLM

/// W5-1a G37: a held recommendation dropped on a playlist or a sync profile is kept in the same
/// undo step (D-INBOX-TO-PLAYLIST: "Keep and add"); otherwise it would sit in the playlist yet
/// stay hidden from All Tracks.
@Suite("HeldRecommendationDropTests", .serialized)
@MainActor
struct HeldRecommendationDropTests {
    struct Env {
        let db: DatabaseQueue
        let playlists: PlaylistRepository
        let sync: SyncRepository
        let recommendations: RecommendationRepository
        let manager: UndoManager
        let status: StatusBarCenter
        let undo: UndoCenter
        let edits: ShellEdits
        let held: Int64
        let plain: Int64
    }

    private func makeEnv() async throws -> Env {
        let db = try DatabaseManager.inMemory()
        let playlists = PlaylistRepository(database: db)
        let sync = SyncRepository(database: db)
        let recommendations = RecommendationRepository(database: db)
        let ids: [Int64] = try await db.write { db in
            try (0..<2).map { try AlbumTracksMigrationTests.insertTrack(db, title: "T\($0)", album: "") }
        }
        try await recommendations.markHeld(trackID: ids[0], seedTrackID: ids[1], source: "soundcloud")
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = ManualSleeper()
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let sidebar = SidebarModel(defaults: UserDefaults(suiteName: "HeldRecommendationDropTests-\(UUID().uuidString)")!)
        let window = ShellWindowModels(navigation: NavigationModel(), sidebar: sidebar, statusBar: status)
        let edits = ShellEdits(
            dependencies: ShellEdits.Dependencies(
                playlists: { playlists }, syncProfiles: { sync }, syncProfileDidChange: { _ in },
                syncContentDidChange: { _ in }, recommendations: { recommendations }),
            undo: undo, window: window)
        return Env(db: db, playlists: playlists, sync: sync, recommendations: recommendations, manager: manager,
                   status: status, undo: undo, edits: edits, held: ids[0], plain: ids[1])
    }

    private func isPending(_ env: Env, _ id: Int64) async throws -> Bool {
        try await env.db.read { db in
            try Int.fetchOne(db, sql: "SELECT is_pending_recommendation FROM tracks WHERE id = ?", arguments: [id]) == 1
        }
    }

    @Test func droppingAHeldTrackOnAPlaylistKeepsItInTheSameStep() async throws {
        let env = try await makeEnv()
        let playlist = try await env.playlists.create(name: "Warm-up")
        let id = try #require(playlist.id)
        #expect(try await isPending(env, env.held))
        await env.edits.addTracks([env.held, env.plain], toPlaylist: id)
        #expect(!(try await isPending(env, env.held)), "kept: it joins All Tracks")
        #expect(try await env.playlists.fetchTracks(playlistId: id).compactMap(\.id) == [env.held, env.plain])
        #expect(env.status.message?.text == "Kept and added 2 tracks to “Warm-up”")
        #expect(env.manager.undoMenuItemTitle == "Undo Add to “Warm-up”")
        env.manager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await isPending(env, env.held), "one Undo: held again")
        #expect(try await env.playlists.fetchTracks(playlistId: id).isEmpty, "and out of the playlist")
        env.manager.redo()
        await env.undo.waitUntilIdle()
        #expect(!(try await isPending(env, env.held)))
        #expect(try await env.playlists.fetchTracks(playlistId: id).count == 2)
    }

    @Test func droppingAHeldTrackOnASyncProfileKeepsItToo() async throws {
        let env = try await makeEnv()
        let profile = try await env.sync.create(name: "Rockbox", outputFolder: "/tmp/out")
        let id = try #require(profile.id)
        await env.edits.addTracks([env.held], toSyncProfile: id, name: "Rockbox")
        #expect(!(try await isPending(env, env.held)))
        #expect(try await env.sync.fetchProfileTracks(profileId: id).compactMap(\.id) == [env.held])
        #expect(env.status.message?.text == "Kept and added 1 track to “Rockbox”")
        env.manager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await isPending(env, env.held))
        #expect(try await env.sync.fetchProfileTracks(profileId: id).isEmpty)
    }

    @Test func tracksThatAreNotHeldAreAddedAsBefore() async throws {
        let env = try await makeEnv()
        let playlist = try await env.playlists.create(name: "Warm-up")
        let id = try #require(playlist.id)
        await env.edits.addTracks([env.plain], toPlaylist: id)
        #expect(env.status.message?.text == "Added 1 track to “Warm-up”")
        #expect(try await isPending(env, env.held), "an untouched held track stays held")
    }

    @Test func aPlacementAtTheInsertionLineKeepsToo() async throws {
        let env = try await makeEnv()
        let playlist = try await env.playlists.create(name: "Warm-up")
        let id = try #require(playlist.id)
        _ = try await env.playlists.appendTracksReturningEntries(playlistId: id, trackIds: [env.plain])
        let plan = try #require(PlaylistDropPlan.make(trackIDs: [env.held], playlistOrder: [env.plain], displayRows: [env.plain],
                                                      insertionIndex: 0, isPlaylistOrder: true, isFiltered: false))
        await env.edits.placeTracks(plan, inPlaylist: id, name: "Warm-up")
        #expect(!(try await isPending(env, env.held)))
        #expect(try await env.playlists.fetchTracks(playlistId: id).compactMap(\.id) == [env.held, env.plain])
        env.manager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await isPending(env, env.held))
        #expect(try await env.playlists.fetchTracks(playlistId: id).compactMap(\.id) == [env.plain])
    }
}
