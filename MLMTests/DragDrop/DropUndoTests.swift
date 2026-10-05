import AppKit
import Foundation
import GRDB
import Testing
@testable import MLM

/// Drops as undo steps on a temporary database (W2-H, UC-UNDO-08): one step per drop; undo
/// restores the exact earlier rows and positions (cover: picture and lock), redo the later ones.
@Suite("Drop undo", .serialized)
@MainActor
struct DropUndoTests {
    @MainActor
    struct Env {
        let db: DatabaseQueue
        let playlists: PlaylistRepository
        let sync: SyncRepository
        let manager: UndoManager
        let status: StatusBarCenter
        let undo: UndoCenter
        let edits: ShellEdits
        let covers: PlaylistCoverService
        let coversDir: URL
    }

    private let sleeper = ManualSleeper()

    private func makeEnv() throws -> Env {
        let db = try DatabaseManager.inMemory()
        let playlists = PlaylistRepository(database: db)
        let sync = SyncRepository(database: db)
        let tracks = TrackRepository(database: db)
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = self.sleeper
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let defaults = UserDefaults(suiteName: "DropUndoTests-\(UUID().uuidString)")!
        let sidebar = SidebarModel(defaults: defaults)
        let window = ShellWindowModels(navigation: NavigationModel(), sidebar: sidebar, statusBar: status)
        let coversDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropUndoTests-\(UUID().uuidString)")
            .appendingPathComponent("playlist-covers")
        let covers = PlaylistCoverService(database: db, playlistRepository: playlists, trackRepository: tracks,
                                          configRepository: ConfigRepository(database: db), coversDirectory: coversDir,
                                          // Its own center: other suites' posts never reach it.
                                          notificationCenter: NotificationCenter())
        let edits = ShellEdits(
            dependencies: ShellEdits.Dependencies(
                playlists: { playlists },
                syncProfiles: { sync },
                syncProfileDidChange: { _ in },
                tracks: { tracks },
                syncContentDidChange: { _ in },
                covers: { covers }
            ),
            undo: undo,
            window: window
        )
        return Env(db: db, playlists: playlists, sync: sync, manager: manager, status: status, undo: undo,
                   edits: edits, covers: covers, coversDir: coversDir)
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

    /// A playlist with a high id (so `.playlistDidChange` posts of other suites never name it).
    private func seedPlaylist(_ env: Env, id: Int64, name: String, tracks: [Int64]) async throws {
        try await env.db.write { db in
            try db.execute(sql: """
                INSERT INTO playlists (id, name, category) VALUES (?, ?, 'regular')
            """, arguments: [id, name])
        }
        try await env.playlists.appendTracks(playlistId: id, trackIds: tracks)
    }

    /// Every row of the playlist: row id, track, position, added date — in playlist order.
    private func rows(_ env: Env, _ playlistID: Int64) async throws -> [[DatabaseValue]] {
        try await env.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, track_id, position, added_at FROM playlist_tracks WHERE playlist_id = ?
                ORDER BY position, added_at, id
            """, arguments: [playlistID]).map { Array($0.databaseValues) }
        }
    }

    private func order(_ env: Env, _ playlistID: Int64) async throws -> [Int64] {
        try await env.playlists.fetchTracks(playlistId: playlistID).compactMap(\.id)
    }

    private func undo(_ env: Env) async {
        env.manager.undo()
        await env.undo.waitUntilIdle()
    }

    private func redo(_ env: Env) async {
        env.manager.redo()
        await env.undo.waitUntilIdle()
    }

    // MARK: Reorder in a playlist (D-PLD-REORDER)

    @Test func aReorderIsOneStepAndUndoRestoresTheExactPositions() async throws {
        let env = try makeEnv()
        try await seedTracks(env, [1, 2, 3, 4, 5])
        try await seedPlaylist(env, id: 910_001, name: "Warm-up", tracks: [1, 2, 3, 4, 5])
        let before = try await rows(env, 910_001)

        let plan = try #require(PlaylistDropPlan.make(trackIDs: [4, 5], playlistOrder: [1, 2, 3, 4, 5], displayRows: [1, 2, 3, 4, 5],
                                                      insertionIndex: 1, isPlaylistOrder: true, isFiltered: false))
        await env.edits.placeTracks(plan, inPlaylist: 910_001, name: "Warm-up")
        #expect(try await order(env, 910_001) == [1, 4, 5, 2, 3])
        #expect(env.status.message?.text == "Moved 2 tracks to position 2 in “Warm-up”")
        #expect(env.manager.undoMenuItemTitle == "Undo Reorder “Warm-up”")
        let after = try await rows(env, 910_001)

        await undo(env)
        #expect(try await rows(env, 910_001) == before, "same rows, same positions, same added dates")

        await redo(env)
        #expect(try await rows(env, 910_001) == after)
    }

    // MARK: Insert at the line (D-PLD-INSERT)

    @Test func anInsertIsOneStepAndUndoRemovesExactlyItsRows() async throws {
        let env = try makeEnv()
        try await seedTracks(env, [1, 2, 3, 7, 8])
        try await seedPlaylist(env, id: 910_002, name: "Warm-up", tracks: [1, 2, 3])
        let before = try await rows(env, 910_002)

        // 8 and 3 dropped before track 2: 8 is new, 3 moves there.
        let plan = try #require(PlaylistDropPlan.make(trackIDs: [8, 3], playlistOrder: [1, 2, 3], displayRows: [1, 2, 3],
                                                      insertionIndex: 1, isPlaylistOrder: true, isFiltered: false))
        await env.edits.placeTracks(plan, inPlaylist: 910_002, name: "Warm-up")
        #expect(try await order(env, 910_002) == [1, 8, 3, 2])
        #expect(env.status.message?.text == "Added 1 track to “Warm-up” at position 2 · 1 already in it moved there")
        #expect(env.manager.undoMenuItemTitle == "Undo Add to “Warm-up”")
        let after = try await rows(env, 910_002)

        await undo(env)
        #expect(try await rows(env, 910_002) == before)

        await redo(env)
        #expect(try await rows(env, 910_002) == after, "the inserted row comes back with its id, position and date")
    }

    @Test func aTrackThatLeftTheLibraryIsNeverInserted() async throws {
        let env = try makeEnv()
        try await seedTracks(env, [1, 2])
        try await seedPlaylist(env, id: 910_003, name: "Warm-up", tracks: [1])
        let plan = PlaylistDropPlan(kind: .insert, trackIDs: [404, 2], beforeTrackID: 1)
        await env.edits.placeTracks(plan, inPlaylist: 910_003, name: "Warm-up")
        #expect(try await order(env, 910_003) == [2, 1])
    }

    @Test func undoAfterAMovedTrackWasRemovedDoesNotAddItBack() async throws {
        let env = try makeEnv()
        try await seedTracks(env, [1, 2, 3])
        try await seedPlaylist(env, id: 910_004, name: "Warm-up", tracks: [1, 2, 3])
        let plan = try #require(PlaylistDropPlan.make(trackIDs: [3], playlistOrder: [1, 2, 3], displayRows: [1, 2, 3],
                                                      insertionIndex: 0, isPlaylistOrder: true, isFiltered: false))
        await env.edits.placeTracks(plan, inPlaylist: 910_004, name: "Warm-up")
        try await env.playlists.removeTrack(playlistId: 910_004, trackId: 3)
        await undo(env)
        #expect(try await order(env, 910_004) == [1, 2], "a removed track is not put back by a position undo")
    }

    // MARK: Sync profile content (D-LIB-TO-SYNC)

    @Test func addingToASyncProfileIsOneStepAndSkipsWhatIsThere() async throws {
        let env = try makeEnv()
        try await seedTracks(env, [1, 2, 3])
        let profile = try await env.sync.create(name: "iPod Classic", outputFolder: "/tmp/ipod-\(UUID().uuidString)")
        let id = try #require(profile.id)
        try await env.sync.addTrack(profileId: id, trackId: 1)

        await env.edits.addTracks([1, 2, 3], toSyncProfile: id, name: "iPod Classic")
        #expect(Set(try await env.sync.fetchProfileTracks(profileId: id).compactMap(\.id)) == [1, 2, 3])
        #expect(env.status.message?.text == "Added 2 tracks to “iPod Classic” · 1 was already in it")
        #expect(env.manager.undoMenuItemTitle == "Undo Add to “iPod Classic”")

        await undo(env)
        #expect(Set(try await env.sync.fetchProfileTracks(profileId: id).compactMap(\.id)) == [1], "only what the drop added goes")
        await redo(env)
        #expect(Set(try await env.sync.fetchProfileTracks(profileId: id).compactMap(\.id)) == [1, 2, 3])

        // Everything already there: no step, a note.
        let steps = env.manager.canUndo
        await env.edits.addTracks([2], toSyncProfile: id, name: "iPod Classic")
        #expect(env.status.message?.text == "The track was already in “iPod Classic”")
        #expect(env.manager.canUndo == steps)
    }

    @Test func addingAPlaylistToASyncProfileIsOneStep() async throws {
        let env = try makeEnv()
        try await seedTracks(env, [1])
        try await seedPlaylist(env, id: 910_005, name: "Warm-up", tracks: [1])
        let profile = try await env.sync.create(name: "iPod Classic", outputFolder: "/tmp/ipod-\(UUID().uuidString)")
        let id = try #require(profile.id)

        await env.edits.addPlaylists([910_005], toSyncProfile: id, name: "iPod Classic")
        #expect(try await env.sync.fetchProfilePlaylists(profileId: id).compactMap(\.id) == [910_005])
        #expect(env.status.message?.text == "Added “Warm-up” to “iPod Classic”")
        await undo(env)
        #expect(try await env.sync.fetchProfilePlaylists(profileId: id).isEmpty)
    }

    // MARK: New playlist named after a dropped folder

    @Test func aFolderDropMakesAPlaylistNamedAfterIt() async throws {
        let env = try makeEnv()
        try await seedTracks(env, [1, 2])
        let created = try #require(await env.edits.newPlaylist(named: "Road trip", fromTrackIDs: [2, 1]))
        #expect(created.name == "Road trip")
        #expect(try await order(env, try #require(created.id)) == [2, 1])
        #expect(env.status.message?.text == "Created “Road trip” with 2 tracks")
        await undo(env)
        #expect(try await env.playlists.fetch(id: try #require(created.id)) == nil)
    }

    // MARK: Cover (D-PL-COVER-TO-CARD, D-PLD-COVER-TO-HEADER)

    @Test func aCoverDropIsOneStepAndUndoRestoresTheEarlierCoverExactly() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.coversDir.deletingLastPathComponent()) }
        try await seedPlaylist(env, id: 910_006, name: "Warm-up", tracks: [])
        // Earlier: a chosen cover (locked, so no automatic regeneration touches it meanwhile).
        try FileManager.default.createDirectory(at: env.coversDir, withIntermediateDirectories: true)
        let earlierBytes = try Self.png(size: 8)
        try earlierBytes.write(to: env.coversDir.appendingPathComponent("910006.png"))
        try await env.playlists.setCoverPath(id: 910_006, path: "playlist-covers/910006.png", isCustom: true)
        let before = try await env.covers.coverState(playlistId: 910_006)

        let refusal = await env.edits.setCover(.data(try Self.png(size: 32)), ofPlaylist: 910_006, name: "Warm-up")
        #expect(refusal == nil)
        let after = try await env.covers.coverState(playlistId: 910_006)
        #expect(after.isCustom && after.png != nil && after.png != earlierBytes)
        #expect(env.status.message?.text == "Set the cover of “Warm-up”")
        #expect(env.manager.undoMenuItemTitle == "Undo Set Cover")

        await undo(env)
        #expect(try await env.covers.coverState(playlistId: 910_006) == before)
        await redo(env)
        #expect(try await env.covers.coverState(playlistId: 910_006) == after)
    }

    @Test func undoOfACoverDropBringsBackTheAutomaticState() async throws {
        let env = try makeEnv()
        defer { try? FileManager.default.removeItem(at: env.coversDir.deletingLastPathComponent()) }
        try await seedPlaylist(env, id: 910_007, name: "Peak time", tracks: [])
        let before = try await env.covers.coverState(playlistId: 910_007)
        #expect(before == PlaylistCoverService.CoverState(path: nil, isCustom: false, png: nil))

        _ = await env.edits.setCover(.data(try Self.png(size: 16)), ofPlaylist: 910_007, name: "Peak time")
        #expect(try await env.covers.coverState(playlistId: 910_007).isCustom)
        await undo(env)
        let restored = try await env.covers.coverState(playlistId: 910_007)
        #expect(restored.path == nil && !restored.isCustom && restored.png == nil, "automatic again, no custom picture left")
    }

    @Test func aFileThatIsNotAnImageIsRefusedWithoutAStep() async throws {
        let env = try makeEnv()
        try await seedPlaylist(env, id: 910_008, name: "Warm-up", tracks: [])
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        let refusal = await env.edits.setCover(.file(text), ofPlaylist: 910_008, name: "Warm-up")
        #expect(refusal == "Couldn’t use “\(text.lastPathComponent)” as a cover. Drop a PNG, JPEG or HEIC image.")
        #expect(!env.manager.canUndo)
        #expect(try await env.playlists.fetch(id: 910_008)?.coverIsCustom == 0)
    }

    // MARK: -

    static func png(size: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<size { for y in 0..<size { rep.setColor(.init(red: CGFloat(x) / CGFloat(size), green: 0.5, blue: 0.2, alpha: 1), atX: x, y: y) } }
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}
