import Foundation
import GRDB
import Testing
@testable import MLM

/// `ShellEdits.setAlbumOrder / addTracks(toAlbum:) / removeTracks(fromAlbum:)` (W4-1, DEC-019):
/// one undo step each, with the status-bar sentence.
@MainActor
@Suite("AlbumEditsUndoTests")
struct AlbumEditsUndoTests {
    struct Env {
        let db: DatabaseQueue
        let manager: UndoManager
        let undo: UndoCenter
        let status: StatusBarCenter
        let edits: ShellEdits
        let repo: AlbumTrackRepository
        let album: Int64
        let ids: [Int64]
    }

    private func makeEnv(members: Int = 3, extra: Int = 2) async throws -> Env {
        let db = try DatabaseManager.inMemory()
        let repo = AlbumTrackRepository(database: db)
        let albums = AlbumRepository(database: db)
        let (album, ids): (Int64, [Int64]) = try await db.write { db in
            try db.execute(sql: "INSERT INTO albums (artist, album_artist, title, title_normalized) VALUES ('O','O','Low Season','lowseason')")
            let album = db.lastInsertedRowID
            let ids = try (0..<(members + extra)).map { try AlbumTracksMigrationTests.insertTrack(db, title: "T\($0)", album: "Low Season") }
            return (album, ids)
        }
        try await repo.add(trackIDs: Array(ids.prefix(members)), to: album)
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = ManualSleeper()
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let window = ShellWindowModels(navigation: NavigationModel(), sidebar: SidebarModel(defaults: UserDefaults(suiteName: "AlbumEditsUndoTests-\(UUID().uuidString)")!), statusBar: status)
        let edits = ShellEdits(
            dependencies: ShellEdits.Dependencies(
                playlists: { PlaylistRepository(database: db) }, syncProfiles: { SyncRepository(database: db) },
                syncProfileDidChange: { _ in }, albumTracks: { repo }, albums: { albums }),
            undo: undo, window: window)
        return Env(db: db, manager: manager, undo: undo, status: status, edits: edits, repo: repo, album: album, ids: ids)
    }

    private func order(_ env: Env) async throws -> [Int64] { try await env.repo.rows(of: env.album).map(\.trackId) }

    @Test func reorderingIsOneStepAndUndoRestoresTheExactRows() async throws {
        let env = try await makeEnv()
        let before = try await env.repo.snapshot(albumID: env.album)
        try await env.edits.setAlbumOrder(albumID: env.album, orderedTrackIDs: [env.ids[2], env.ids[0], env.ids[1]])
        #expect(try await order(env) == [env.ids[2], env.ids[0], env.ids[1]])
        #expect(env.status.message?.text == "Reordered “Low Season”")
        #expect(env.manager.undoMenuItemTitle == "Undo Reorder “Low Season”")
        env.manager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await env.repo.snapshot(albumID: env.album) == before)
        env.manager.redo()
        await env.undo.waitUntilIdle()
        #expect(try await order(env) == [env.ids[2], env.ids[0], env.ids[1]])
    }

    @Test func reorderingATwoDiscAlbumKeepsEveryDiscAndNumbersPerDisc() async throws {
        let env = try await makeEnv()
        let (a, b, c) = (env.ids[0], env.ids[1], env.ids[2])
        try await env.repo.setNumbers(albumID: env.album, [a: (1, 1), b: (1, 2), c: (2, 1)])
        let before = try await env.repo.snapshot(albumID: env.album)
        try await env.edits.setAlbumOrder(albumID: env.album, orderedTrackIDs: [c, b, a])
        let rows = try await env.repo.rows(of: env.album)
        #expect(rows.map(\.trackId) == [b, a, c], "disc 1 reordered, disc 2 untouched")
        #expect(rows.map(\.disc) == [1, 1, 2], "no disc is flattened")
        #expect(rows.map(\.trackNumber) == [1, 2, 1], "numbers 1…k within each disc")
        env.manager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await env.repo.snapshot(albumID: env.album) == before)
    }

    @Test func undoAfterTheAlbumWasDeletedRefusesAndWritesNothing() async throws {
        let env = try await makeEnv()
        try await env.edits.setAlbumOrder(albumID: env.album, orderedTrackIDs: [env.ids[2], env.ids[0], env.ids[1]])
        try await AlbumRepository(database: env.db).delete(id: env.album)
        env.manager.undo()
        await env.undo.waitUntilIdle()
        #expect(env.status.message?.text == "Couldn’t undo Reorder “Low Season” — the album no longer exists")
        let (rows, linked) = try await env.db.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_tracks WHERE album_id = ?", arguments: [env.album]),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE album_id = ?", arguments: [env.album]))
        }
        #expect(rows == 0 && linked == 0, "no orphan rows, no track pointed at the deleted album")
    }

    @Test func anAlbumEditIsOneTransactionSoAFailureLeavesNothing() async throws {
        let env = try await makeEnv()
        let before = try await env.repo.snapshot(albumID: env.album)
        struct Boom: Error {}
        let (album, extra) = (env.album, env.ids[3])
        await #expect(throws: Boom.self) {
            _ = try await env.repo.edit(albumID: album) { db in
                try AlbumTrackRepository.addRows(db, trackIDs: [extra], to: album)
                throw Boom()
            }
        }
        #expect(try await env.repo.snapshot(albumID: env.album) == before, "the half-done edit was rolled back")
    }

    @Test func aReorderThatChangesNothingLeavesNoStep() async throws {
        let env = try await makeEnv()
        // Numbered 1, 2, 3 in this order already: the same order again changes nothing.
        try await env.repo.setNumbers(albumID: env.album, [env.ids[0]: (1, 1), env.ids[1]: (1, 2), env.ids[2]: (1, 3)])
        try await env.edits.setAlbumOrder(albumID: env.album, orderedTrackIDs: Array(env.ids.prefix(3)))
        #expect(env.manager.undoMenuItemTitle == "Undo", "no step")
        #expect(env.status.message == nil)
    }

    @Test func addingTracksSaysHowManyAndUndoRemovesThem() async throws {
        let env = try await makeEnv()
        try await env.edits.addTracks(toAlbum: env.album, trackIDs: [env.ids[0], env.ids[3], env.ids[4]])
        #expect(try await order(env).count == 5)
        #expect(env.status.message?.text == "Added 2 tracks to “Low Season”", "the member already there is not counted")
        #expect(env.manager.undoMenuItemTitle == "Undo Add to “Low Season”")
        env.manager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await order(env) == Array(env.ids.prefix(3)))
        let link = try await env.db.read { db in try Int64?.fetchOne(db, sql: "SELECT album_id FROM tracks WHERE id = ?", arguments: [env.ids[3]]) }
        #expect(link == .some(nil), "the track link goes with the row")
    }

    @Test func removingTracksAndUndoPutsRowsAndLinksBack() async throws {
        let env = try await makeEnv()
        let before = try await env.repo.snapshot(albumID: env.album)
        try await env.edits.removeTracks(fromAlbum: env.album, trackIDs: [env.ids[0]])
        #expect(env.status.message?.text == "Removed 1 track from “Low Season”")
        #expect(try await order(env) == [env.ids[1], env.ids[2]])
        env.manager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await env.repo.snapshot(albumID: env.album) == before)
    }

    @Test func aMissingAlbumThrowsPlainly() async throws {
        let env = try await makeEnv()
        await #expect(throws: UndoTargetMissing.self) {
            try await env.edits.addTracks(toAlbum: 99_999, trackIDs: [env.ids[0]])
        }
    }
}
