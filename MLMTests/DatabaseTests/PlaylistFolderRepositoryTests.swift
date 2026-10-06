import Foundation
import GRDB
import Testing
@testable import MLM

/// Playlist folders and the manual order (v45, UC-SIDE-08, DEC-003). Temporary databases only.
@Suite("PlaylistFolderRepositoryTests")
struct PlaylistFolderRepositoryTests {
    private struct Fixture {
        let db: DatabaseQueue
        let playlists: PlaylistRepository
        let folders: PlaylistFolderRepository

        init() throws {
            db = try DatabaseManager.inMemory()
            playlists = PlaylistRepository(database: db)
            folders = playlists.folders
        }

        func names() async throws -> [String] {
            try await playlists.fetchAll().map(\.name)
        }

        func tree() async throws -> PlaylistSidebarTree {
            PlaylistSidebarTree.build(folders: try await folders.fetchFolders(), playlists: try await playlists.fetchAll())
        }

        func topLevelNames() async throws -> [String] {
            try await tree().nodes.map { node in
                switch node {
                case .folder(let folder, _): "[\(folder.name)]"
                case .playlist(let playlist): playlist.name
                }
            }
        }

        func insertTrack(_ title: String) throws -> Int64 {
            try db.write { db in
                try db.execute(sql: """
                    INSERT INTO tracks (artist, album_artist, album, title, format, original_path, is_duplicate, duration)
                    VALUES ('A', 'A', 'B', ?, 'm4a', ?, 0, 200)
                """, arguments: [title, "/orig/\(title).m4a"])
                return db.lastInsertedRowID
            }
        }
    }

    @Test func newPlaylistsAndFoldersGoFirstAndAreNumbered() async throws {
        let f = try Fixture()
        _ = try await f.playlists.createNumbered(baseName: "Untitled Playlist")
        _ = try await f.playlists.createNumbered(baseName: "Untitled Playlist")
        let folder = try await f.folders.createFolder()
        let second = try await f.folders.createFolder()
        #expect(folder.name == "untitled folder")
        #expect(second.name == "untitled folder 2")
        #expect(try await f.topLevelNames() == ["[untitled folder 2]", "[untitled folder]", "Untitled Playlist 2", "Untitled Playlist"])
    }

    @Test func newPlaylistInAFolderGoesLastInIt() async throws {
        let f = try Fixture()
        let folder = try await f.folders.createFolder(baseName: "Sets")
        _ = try await f.playlists.createNumbered(baseName: "Warm-up", inFolder: folder.id)
        _ = try await f.playlists.createNumbered(baseName: "Peak time", inFolder: folder.id)
        let tree = try await f.tree()
        #expect(tree.nodes.count == 1)
        guard case .folder(_, let children) = tree.nodes[0] else { Issue.record("expected a folder"); return }
        #expect(children.map(\.name) == ["Warm-up", "Peak time"])
        #expect(try await f.names() == ["Warm-up", "Peak time"], "fetchAll lists a folder's playlists in its place")
    }

    @Test func moveIntoAFolderBetweenRowsAndBackOutIsExactOnUndo() async throws {
        let f = try Fixture()
        let c = try await f.playlists.createNumbered(baseName: "C")
        let b = try await f.playlists.createNumbered(baseName: "B")
        let a = try await f.playlists.createNumbered(baseName: "A")
        let sets = try await f.folders.createFolder(baseName: "Sets")
        #expect(try await f.topLevelNames() == ["[Sets]", "A", "B", "C"])

        // Into the folder.
        let into = try await f.folders.move([.playlist(b.id!)], into: sets.id, before: nil)
        #expect(try await f.topLevelNames() == ["[Sets]", "A", "C"])
        #expect(try await f.tree().folder(containing: b.id!)?.id == sets.id)

        // Reorder at the top level: C before A.
        let reorder = try await f.folders.move([.playlist(c.id!)], into: nil, before: .playlist(a.id!))
        #expect(try await f.topLevelNames() == ["[Sets]", "C", "A"])

        // Folder to the end.
        let folderMove = try await f.folders.move([.folder(sets.id!)], into: nil, before: nil)
        #expect(try await f.topLevelNames() == ["C", "A", "[Sets]"])

        // Undo newest first: exactly back.
        _ = try await f.folders.revert(folderMove)
        #expect(try await f.topLevelNames() == ["[Sets]", "C", "A"])
        _ = try await f.folders.revert(reorder)
        #expect(try await f.topLevelNames() == ["[Sets]", "A", "C"])
        let undone = try await f.folders.revert(into)
        #expect(try await f.topLevelNames() == ["[Sets]", "A", "B", "C"])
        // Redo.
        _ = try await f.folders.revert(undone)
        #expect(try await f.tree().folder(containing: b.id!)?.id == sets.id)
    }

    @Test func aFolderNeverGoesIntoAFolder() async throws {
        let f = try Fixture()
        let outer = try await f.folders.createFolder(baseName: "Outer")
        let inner = try await f.folders.createFolder(baseName: "Inner")
        let change = try await f.folders.move([.folder(inner.id!)], into: outer.id, before: nil)
        #expect(change.isEmpty)
        #expect(try await f.topLevelNames() == ["[Inner]", "[Outer]"])
    }

    @Test func undoLeavesARowAloneThatMovedAgainSince() async throws {
        let f = try Fixture()
        let a = try await f.playlists.createNumbered(baseName: "A")
        let sets = try await f.folders.createFolder(baseName: "Sets")
        let crates = try await f.folders.createFolder(baseName: "Crates")
        let first = try await f.folders.move([.playlist(a.id!)], into: sets.id, before: nil)
        _ = try await f.folders.move([.playlist(a.id!)], into: crates.id, before: nil)
        let applied = try await f.folders.revert(first)
        #expect(applied.before.isEmpty, "A is no longer where the first move left it")
        #expect(try await f.tree().folder(containing: a.id!)?.id == crates.id)
    }

    /// UC-SIDE-08: deleting a folder moves its playlists up one level, never deletes them.
    @Test func deletingAFolderMovesItsPlaylistsOutWhereItWasAndUndoPutsThemBack() async throws {
        let f = try Fixture()
        let z = try await f.playlists.createNumbered(baseName: "Z")
        let sets = try await f.folders.createFolder(baseName: "Sets")
        let a = try await f.playlists.createNumbered(baseName: "A")
        _ = try await f.playlists.createNumbered(baseName: "Warm-up", inFolder: sets.id)
        _ = try await f.playlists.createNumbered(baseName: "Peak time", inFolder: sets.id)
        #expect(try await f.topLevelNames() == ["A", "[Sets]", "Z"])
        _ = (z, a)

        let snapshot = try await f.folders.deleteFolderReturningSnapshot(id: sets.id!)
        #expect(try await f.topLevelNames() == ["A", "Warm-up", "Peak time", "Z"])
        #expect(try await f.playlists.fetchAll().count == 4, "no playlist is deleted")
        #expect(try await f.folders.fetchFolders().isEmpty)

        let restored = try await f.folders.restoreFolder(snapshot)
        #expect(restored.id == sets.id, "same id when free")
        #expect(try await f.topLevelNames() == ["A", "[Sets]", "Z"])
        let tree = try await f.tree()
        guard case .folder(_, let children) = tree.nodes[1] else { Issue.record("expected the folder"); return }
        #expect(children.map(\.name) == ["Warm-up", "Peak time"])
    }

    @Test func renameRefusesAnotherFoldersNameInAnyCase() async throws {
        let f = try Fixture()
        let sets = try await f.folders.createFolder(baseName: "Sets")
        let other = try await f.folders.createFolder(baseName: "Radio")
        await #expect(throws: PlaylistFolderError.nameTaken("Sets")) {
            try await f.folders.renameFolder(id: other.id!, to: "sets")
        }
        try await f.folders.renameFolder(id: sets.id!, to: "SETS")
        #expect(try await f.folders.fetchFolder(id: sets.id!)?.name == "SETS")
    }

    @Test func aPlaylistWhoseFolderIsGoneIsATopLevelRow() async throws {
        let f = try Fixture()
        let sets = try await f.folders.createFolder(baseName: "Sets")
        let inside = try await f.playlists.createNumbered(baseName: "Inside", inFolder: sets.id)
        try await f.db.write { db in try db.execute(sql: "DELETE FROM playlist_folders") }
        #expect(try await f.topLevelNames() == ["Inside"])
        #expect(try await f.playlists.fetchAll().map(\.id) == [inside.id])
    }

    /// W2-F delete / restore carries the folder and position (W3-PL).
    @Test func aRestoredPlaylistReturnsToItsFolderAndPlace() async throws {
        let f = try Fixture()
        let sets = try await f.folders.createFolder(baseName: "Sets")
        _ = try await f.playlists.createNumbered(baseName: "Warm-up", inFolder: sets.id)
        let peak = try await f.playlists.createNumbered(baseName: "Peak time", inFolder: sets.id)
        _ = try await f.playlists.createNumbered(baseName: "Closing", inFolder: sets.id)
        let snapshot = try await f.playlists.deleteReturningSnapshot(id: peak.id!)
        _ = try await f.playlists.restore(snapshot)
        let tree = try await f.tree()
        guard case .folder(_, let children) = tree.nodes[0] else { Issue.record("expected the folder"); return }
        #expect(children.map(\.name) == ["Warm-up", "Peak time", "Closing"])
    }

    @Test func aRestoredPlaylistWhoseFolderWasDeletedComesBackAtTheTopLevel() async throws {
        let f = try Fixture()
        let sets = try await f.folders.createFolder(baseName: "Sets")
        let peak = try await f.playlists.createNumbered(baseName: "Peak time", inFolder: sets.id)
        let snapshot = try await f.playlists.deleteReturningSnapshot(id: peak.id!)
        _ = try await f.folders.deleteFolderReturningSnapshot(id: sets.id!)
        let result = try await f.playlists.restore(snapshot)
        #expect(result.playlist.folderId == nil)
        #expect(try await f.topLevelNames() == ["Peak time"])
    }

    /// UC §23 C10: the Liked playlist can be deleted (and restored).
    @Test func theLikedPlaylistCanBeDeletedAndRestored() async throws {
        let f = try Fixture()
        let liked = try await f.playlists.findOrCreateLikedPlaylist(name: "Liked from SoundCloud", sourceId: 1, externalId: "42")
        let snapshot = try await f.playlists.deleteReturningSnapshot(id: liked.id!)
        #expect(try await f.playlists.fetch(id: liked.id!) == nil)
        let restored = try await f.playlists.restore(snapshot)
        #expect(restored.playlist.isLiked == 1)
    }

    @Test func playlistsCreatedWithoutAPositionComeLastByNameAndGetOneWhenMoved() async throws {
        let f = try Fixture()
        let a = try await f.playlists.createNumbered(baseName: "Mine")
        // An import inserts rows without a position.
        try await f.db.write { db in
            try db.execute(sql: "INSERT INTO playlists (name, category) VALUES ('Zed import', 'synced'), ('Alpha import', 'synced')")
        }
        #expect(try await f.names() == ["Mine", "Alpha import", "Zed import"])
        let zed = try #require(try await f.playlists.findByName("Zed import"))
        let change = try await f.folders.move([.playlist(zed.id!)], into: nil, before: .playlist(a.id!))
        #expect(try await f.names() == ["Zed import", "Mine", "Alpha import"])
        _ = try await f.folders.revert(change)
        let unplaced = try await f.db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM playlists WHERE position IS NULL ORDER BY name")
        }
        #expect(unplaced == ["Alpha import", "Zed import"], "undo is exact, even for the rows a move had to place")
        #expect(try await f.names() == ["Mine", "Alpha import", "Zed import"])
    }

    @Test func summariesCountEveryStateInOneQuery() async throws {
        let f = try Fixture()
        let local = try f.insertTrack("Local")
        let missing = try f.insertTrack("Missing")
        let failed = try f.insertTrack("Failed")
        let notDownloaded = try f.insertTrack("Remote")
        let downloading = try f.insertTrack("Downloading")
        try await f.db.write { db in
            try db.execute(sql: "UPDATE tracks SET organized_path = 'a.m4a' WHERE id = ?", arguments: [local])
            try db.execute(sql: "UPDATE tracks SET organized_path = 'b.m4a' WHERE id = ?", arguments: [missing])
            try db.execute(sql: "UPDATE tracks SET file_missing_since = '2026-01-01T00:00:00Z' WHERE id = ?", arguments: [missing])
            try db.execute(sql: "UPDATE tracks SET download_failure = 'x' WHERE id = ?", arguments: [failed])
            try db.execute(sql: "UPDATE tracks SET download_status = 'downloading' WHERE id = ?", arguments: [downloading])
        }
        let playlist = try await f.playlists.createNumbered(baseName: "Mix", trackIds: [local, missing, failed, notDownloaded, downloading])
        let empty = try await f.playlists.createNumbered(baseName: "Empty")
        let summaries = try await f.playlists.fetchSummaries()
        let summary = try #require(summaries[playlist.id!])
        #expect(summary.totalTracks == 5)
        #expect(summary.localTracks == 1)
        #expect(summary.fileMissingTracks == 1)
        #expect(summary.failedTracks == 1)
        #expect(summary.notDownloadedTracks == 1)
        #expect(summary.downloadingTracks == 1)
        #expect(summary.totalSeconds == 1000)
        #expect(summary.lastAddedAt != nil)
        #expect(summaries[empty.id!] == nil)
        #expect(try await f.playlists.fetchSummary(playlistID: empty.id!).totalTracks == 0)
    }
}
