import Foundation
import GRDB
import Testing
@testable import MLM

/// W3-PL undoable edits (UC-UNDO-02/07/08): playlist folders, moves, link, M3U import into the
/// open playlist (PP-PLAYLISTS-01). Temporary databases; an injected defaults suite.
@Suite("Playlist folder and W3-PL edits")
@MainActor
struct PlaylistFolderEditsTests {
    @MainActor
    struct Env {
        let db: DatabaseQueue
        let playlists: PlaylistRepository
        let manager: UndoManager
        let status: StatusBarCenter
        let undo: UndoCenter
        let sidebar: SidebarModel
        let edits: ShellEdits

        func tree() async throws -> PlaylistSidebarTree {
            PlaylistSidebarTree.build(folders: try await playlists.folders.fetchFolders(), playlists: try await playlists.fetchAll())
        }

        func topLevel() async throws -> [String] {
            try await tree().nodes.map { node in
                switch node {
                case .folder(let folder, let children): "[\(folder.name): \(children.map(\.name).joined(separator: ", "))]"
                case .playlist(let playlist): playlist.name
                }
            }
        }

        func undoOnce() async {
            manager.undo()
            await undo.waitUntilIdle()
        }

        func redoOnce() async {
            manager.redo()
            await undo.waitUntilIdle()
        }
    }

    private let sleeper = ManualSleeper()

    private func makeEnv() throws -> Env {
        let db = try DatabaseManager.inMemory()
        let playlists = PlaylistRepository(database: db)
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = self.sleeper
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let sidebar = SidebarModel(defaults: UserDefaults(suiteName: "PlaylistFolderEditsTests-\(UUID().uuidString)")!)
        let window = ShellWindowModels(navigation: NavigationModel(), sidebar: sidebar, statusBar: status)
        let edits = ShellEdits(
            dependencies: ShellEdits.Dependencies(playlists: { playlists }, syncProfiles: { nil }, syncProfileDidChange: { _ in }),
            undo: undo,
            window: window
        )
        return Env(db: db, playlists: playlists, manager: manager, status: status, undo: undo, sidebar: sidebar, edits: edits)
    }

    @Test func newFolderIsOneStepInRenameModeAndRedoBringsBackTheSameFolder() async throws {
        let env = try makeEnv()
        _ = try await env.playlists.createNumbered(baseName: "Warm-up")
        let folder = try #require(await env.edits.newPlaylistFolder())
        #expect(folder.name == "untitled folder")
        #expect(env.sidebar.folderRenameRequest == folder.id, "created in rename mode (S-PLFOLDER-NEW)")
        #expect(env.status.message?.text == "Created the playlist folder “untitled folder” — drag playlists onto it")
        #expect(env.manager.undoActionName == "New Playlist Folder")
        #expect(try await env.topLevel() == ["[untitled folder: ]", "Warm-up"])
        await env.undoOnce()
        #expect(try await env.topLevel() == ["Warm-up"])
        await env.redoOnce()
        #expect(try await env.playlists.folders.fetchFolders().map(\.id) == [folder.id])
    }

    @Test func deletingAFolderNeverDeletesItsPlaylistsAndUndoPutsThemBack() async throws {
        let env = try makeEnv()
        let sets = try await env.playlists.folders.createFolder(baseName: "Sets")
        _ = try await env.playlists.createNumbered(baseName: "Warm-up", inFolder: sets.id)
        _ = try await env.playlists.createNumbered(baseName: "Closing", inFolder: sets.id)
        await env.edits.deletePlaylistFolder(sets.id!, name: "Sets")
        #expect(env.status.message?.text == "Deleted the folder “Sets” — its 2 playlists moved out of it, none was deleted")
        #expect(env.manager.undoActionName == "Delete “Sets”")
        #expect(try await env.topLevel() == ["Warm-up", "Closing"])
        await env.undoOnce()
        #expect(try await env.topLevel() == ["[Sets: Warm-up, Closing]"])
        await env.redoOnce()
        #expect(try await env.topLevel() == ["Warm-up", "Closing"])
    }

    @Test func renameFolderIsUndoableAndRefusesATakenName() async throws {
        let env = try makeEnv()
        let sets = try await env.playlists.folders.createFolder(baseName: "Sets")
        _ = try await env.playlists.folders.createFolder(baseName: "Radio")
        try await env.edits.renamePlaylistFolder(sets.id!, from: "Sets", to: "Club sets")
        #expect(env.manager.undoActionName == "Rename Playlist Folder")
        await #expect(throws: PlaylistFolderError.self) {
            try await env.edits.renamePlaylistFolder(sets.id!, from: "Club sets", to: "radio")
        }
        await env.undoOnce()
        #expect(try await env.playlists.folders.fetchFolder(id: sets.id!)?.name == "Sets")
    }

    @Test func movingIntoAFolderAndReorderingAreOneStepEach() async throws {
        let env = try makeEnv()
        let b = try await env.playlists.createNumbered(baseName: "B")
        let a = try await env.playlists.createNumbered(baseName: "A")
        let sets = try await env.playlists.folders.createFolder(baseName: "Sets")
        _ = await env.sidebar.reloadPlaylists(env.playlists)
        await env.edits.movePlaylistItems([.playlist(a.id!), .playlist(b.id!)], into: sets.id, before: nil)
        #expect(env.manager.undoActionName == "Move to “Sets”")
        #expect(env.status.message?.text == "Moved 2 playlists to the folder “Sets”")
        #expect(try await env.topLevel() == ["[Sets: A, B]"])
        _ = await env.sidebar.reloadPlaylists(env.playlists)
        await env.edits.movePlaylistItems([.playlist(b.id!)], into: sets.id, before: .playlist(a.id!))
        #expect(env.manager.undoActionName == "Reorder Playlists")
        #expect(try await env.topLevel() == ["[Sets: B, A]"])
        await env.undoOnce()
        #expect(try await env.topLevel() == ["[Sets: A, B]"])
        await env.undoOnce()
        #expect(try await env.topLevel() == ["[Sets: ]", "A", "B"])
    }

    @Test func newPlaylistInAFolderFromDroppedTracks() async throws {
        let env = try makeEnv()
        let sets = try await env.playlists.folders.createFolder(baseName: "Sets")
        try await env.db.write { db in
            try db.execute(sql: "INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path) VALUES (1, 'A', 'A', '', 'One', 'mp3', '/t/1.mp3')")
        }
        let created = try #require(await env.edits.newPlaylist(inFolder: sets.id!, trackIDs: [1]))
        #expect(try await env.topLevel() == ["[Sets: \(created.name)]"])
        await env.undoOnce()
        #expect(try await env.topLevel() == ["[Sets: ]"])
    }

    @Test func linkingIsUndoableAndAddsNoTrack() async throws {
        let env = try makeEnv()
        let playlist = try await env.playlists.createNumbered(baseName: "Warm-up")
        try await env.edits.linkPlaylist(playlist.id!, name: "Warm-up",
                                         to: PlaylistSourceLink(sourceID: 7, externalID: "https://x"), sourceName: "SoundCloud")
        #expect(env.status.message?.text == "Linked “Warm-up” to SoundCloud — nothing was added or removed")
        #expect(env.manager.undoActionName == "Link “Warm-up”")
        #expect(try await env.playlists.fetch(id: playlist.id!)?.sourceId == 7)
        await env.undoOnce()
        let after = try await env.playlists.fetch(id: playlist.id!)
        #expect(after?.sourceId == nil)
        #expect(after?.externalId == nil)
    }

    /// PP-PLAYLISTS-01: `Import M3U into This Playlist…` imports into the open playlist — even
    /// when another playlist has the file's name — and undo removes exactly those rows.
    @Test func m3uGoesIntoTheOpenPlaylistNotTheOneNamedAfterTheFile() async throws {
        let env = try makeEnv()
        try await env.db.write { db in
            for id in 1...3 {
                try db.execute(sql: """
                    INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, mlm_uuid)
                    VALUES (?, 'A', 'A', '', ?, 'mp3', ?, ?)
                """, arguments: [id, "T\(id)", "/t/\(id).mp3", "UUID-\(id)"])
            }
        }
        let warmUp = try await env.playlists.createNumbered(baseName: "Warm-up", trackIds: [1])
        let namesake = try await env.playlists.createNumbered(baseName: "Old iPod")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("m3u-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Old iPod.m3u8")
        try """
        #EXTM3U
        #EXTMLM-PLAYLIST:\(namesake.mlmUuid ?? "NONE")
        #EXTMLM:UUID-1
        /Music/1.mp3
        #EXTMLM:UUID-2
        /Music/2.mp3
        #EXTMLM:UUID-3
        /Music/3.mp3
        /Music/missing-track-that-matches-nothing.mp3
        """.write(to: file, atomically: true, encoding: .utf8)

        let ingest = PlaylistIngestService(trackRepository: TrackRepository(database: env.db), playlistRepository: env.playlists, database: env.db)
        let existing = Set(try await env.playlists.fetchTracks(playlistId: warmUp.id!).compactMap(\.id))
        let plan = try await PlaylistM3U.plan(url: file, ingest: ingest, existing: existing)
        #expect(plan.toAdd == [2, 3])
        #expect(plan.alreadyPresent == 1)
        #expect(plan.notFound.count == 1)
        #expect(plan.summary(destination: "Warm-up") == "2 tracks will be added to the end of “Warm-up”.")
        #expect(plan.skippedText(intoExisting: true)
                == "Nothing is removed or reordered. 1 entry is already in this playlist and 1 can’t be found in the library.")
        #expect(plan.primaryTitle(intoExisting: true) == "Add 2 Tracks")
        #expect(M3UImportPlan.title(fileName: "Old iPod.m3u8", destination: "Warm-up") == "Import “Old iPod.m3u8” into “Warm-up”")

        await env.edits.importM3U(plan, intoPlaylist: warmUp.id!, name: "Warm-up")
        #expect(try await env.playlists.fetchTracks(playlistId: warmUp.id!).compactMap(\.id) == [1, 2, 3])
        #expect(try await env.playlists.fetchTracks(playlistId: namesake.id!).isEmpty, "the playlist named after the file is untouched")
        #expect(env.status.message?.text == "Added 2 tracks to “Warm-up” · 1 already there · 1 not found")
        await env.undoOnce()
        #expect(try await env.playlists.fetchTracks(playlistId: warmUp.id!).compactMap(\.id) == [1])
    }

    @Test func m3uAsANewPlaylistIsNamedAfterTheFile() async throws {
        let env = try makeEnv()
        let plan = M3UImportPlan.make(fileName: "Gym.m3u", entries: [("/a.mp3", nil, nil)], existing: [])
        #expect(plan.toAdd.isEmpty)
        #expect(plan.primaryTitle(intoExisting: false) == "Create Playlist with 0 Tracks")
        try await env.db.write { db in
            try db.execute(sql: "INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path) VALUES (5, 'A', 'A', '', 'Five', 'mp3', '/t/5.mp3')")
        }
        let real = M3UImportPlan.make(fileName: "Gym.m3u", entries: [("/5.mp3", 5, "Five — A"), ("/x.mp3", nil, nil)], existing: [])
        let created = try #require(await env.edits.importM3UAsNewPlaylist(real, named: real.playlistName))
        #expect(created.name == "Gym")
        #expect(env.status.message?.text == "Created “Gym” with 1 track · 1 not found")
        await env.undoOnce()
        #expect(try await env.playlists.fetch(id: created.id!) == nil)
    }

    // MARK: Positions that can't fit (W3-PL review B2/B3, S5)

    private func seedTracks(_ env: Env, _ count: Int) throws {
        try env.db.write { db in
            for id in 1...count {
                try db.execute(sql: "INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path) VALUES (?, 'A', 'A', '', ?, 'mp3', ?)",
                               arguments: [id, "T\(id)", "/t/\(id).mp3"])
            }
        }
    }

    private func positions(_ env: Env, _ playlistID: Int64) throws -> [Int64: String] {
        try env.db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT track_id, position FROM playlist_tracks WHERE playlist_id = ?",
                                                              arguments: [playlistID]).map { ($0["track_id"] as Int64, $0["position"] as String) })
        }
    }

    /// B2: a track dragged to the top of an imported playlist (`%012d` keys) lands at the top;
    /// the playlist is renumbered in the same step and undo puts every old key back.
    @Test func dropToTheTopOfAnImportedPlaylistRenumbersAndUndoesExactly() async throws {
        let env = try makeEnv()
        try seedTracks(env, 5)
        let playlist = try await env.playlists.createNumbered(baseName: "Imported")
        try await env.db.write { db in
            for id in 1...4 {
                try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)",
                               arguments: [playlist.id!, id, String(format: "%012d", id - 1)])
            }
        }
        let original = try positions(env, playlist.id!)
        let plan = try #require(PlaylistDropPlan.make(trackIDs: [5], playlistOrder: [1, 2, 3, 4], displayRows: [1, 2, 3, 4],
                                                      insertionIndex: 0, isPlaylistOrder: true, isFiltered: false))
        await env.edits.placeTracks(plan, inPlaylist: playlist.id!, name: "Imported")
        #expect(try await env.playlists.fetchTracks(playlistId: playlist.id!).compactMap(\.id) == [5, 1, 2, 3, 4])
        await env.undoOnce()
        #expect(try positions(env, playlist.id!) == original, "every old key back")
        await env.redoOnce()
        #expect(try await env.playlists.fetchTracks(playlistId: playlist.id!).compactMap(\.id) == [5, 1, 2, 3, 4])
    }

    /// B3: a playlist with keys over 256 bytes is renumbered by its next edit (same order).
    @Test func longLegacyKeysAreRenumberedByTheNextAppend() async throws {
        let env = try makeEnv()
        try seedTracks(env, 4)
        let playlist = try await env.playlists.createNumbered(baseName: "Old")
        try await env.db.write { db in
            var key = "a0"
            for id in 1...3 {
                key += String(repeating: "|a0", count: 100)
                try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)",
                               arguments: [playlist.id!, id, key])
            }
        }
        await env.edits.addTracks([4], toPlaylist: playlist.id!)
        #expect(try await env.playlists.fetchTracks(playlistId: playlist.id!).compactMap(\.id) == [1, 2, 3, 4])
        #expect(try positions(env, playlist.id!).values.allSatisfy { $0.utf8.count < 16 })
        await env.undoOnce()
        let restored = try positions(env, playlist.id!)
        #expect(restored.count == 3)
        #expect(restored.values.allSatisfy { $0.utf8.count > 256 }, "undo puts the old keys back")
    }

    /// B2 for the sidebar order: playlists with `%012d` positions; one moved to the top.
    @Test func sidebarMoveToTheTopOfAllZeroKeysRenumbersAndRevertsExactly() async throws {
        let env = try makeEnv()
        try await env.db.write { db in
            for (index, name) in ["A", "B", "C"].enumerated() {
                try db.execute(sql: "INSERT INTO playlists (name, category, position) VALUES (?, 'regular', ?)",
                               arguments: [name, String(format: "%012d", index)])
            }
        }
        let c = try #require(try await env.playlists.findByName("C"))
        let a = try #require(try await env.playlists.findByName("A"))
        let before = try await env.db.read { db in try String.fetchAll(db, sql: "SELECT position FROM playlists ORDER BY id") }
        let change = try await env.playlists.folders.move([.playlist(c.id!)], into: nil, before: .playlist(a.id!))
        #expect(try await env.topLevel() == ["C", "A", "B"])
        _ = try await env.playlists.folders.revert(change)
        let after = try await env.db.read { db in try String.fetchAll(db, sql: "SELECT position FROM playlists ORDER BY id") }
        #expect(after == before)
    }

    /// S5: moving a playlist to where it already is changes nothing and records no step.
    @Test func aMoveToTheSamePlaceIsANoOp() async throws {
        let env = try makeEnv()
        let b = try await env.playlists.createNumbered(baseName: "B")
        let a = try await env.playlists.createNumbered(baseName: "A")
        let sets = try await env.playlists.folders.createFolder(baseName: "Sets")
        _ = (a, b)
        #expect(try await env.playlists.folders.move([.playlist(b.id!)], into: nil, before: nil).isEmpty, "already last")
        #expect(try await env.playlists.folders.move([.playlist(a.id!)], into: nil, before: .playlist(b.id!)).isEmpty,
                "dropped back into its own gap")
        #expect(try await env.playlists.folders.move([.folder(sets.id!)], into: nil, before: .folder(sets.id!)).isEmpty)
        _ = await env.sidebar.reloadPlaylists(env.playlists)
        await env.edits.movePlaylistItems([.playlist(b.id!)], into: nil, before: nil)
        #expect(!env.manager.canUndo, "no step recorded")
    }
}
