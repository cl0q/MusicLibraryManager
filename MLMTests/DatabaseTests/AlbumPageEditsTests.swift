import AppKit
import Foundation
import GRDB
import Testing
@testable import MLM

/// The undoable edits of the album page (W4-2): Edit Order's Done with discs and numbers, Set
/// Cover, Choose Edition; the cover files; the drops on a card; the dragged album card.
@MainActor
@Suite("AlbumPageEditsTests")
struct AlbumPageEditsTests {
    typealias Library = AlbumListingTests.Library

    struct Env {
        let lib: Library
        let manager: UndoManager
        let undo: UndoCenter
        let status: StatusBarCenter
        let edits: ShellEdits
    }

    private func makeEnv() throws -> Env {
        let lib = try Library()
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = ManualSleeper()
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let window = ShellWindowModels(navigation: NavigationModel(),
                                       sidebar: SidebarModel(defaults: UserDefaults(suiteName: "AlbumPageEditsTests-\(UUID().uuidString)")!),
                                       statusBar: status)
        let db = lib.db
        let edits = ShellEdits(
            dependencies: ShellEdits.Dependencies(
                playlists: { PlaylistRepository(database: db) }, syncProfiles: { SyncRepository(database: db) },
                syncProfileDidChange: { _ in }, albumTracks: { lib.joins }, albums: { lib.albums }),
            undo: undo, window: window)
        return Env(lib: lib, manager: manager, undo: undo, status: status, edits: edits)
    }

    private func png() throws -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MLM-album-covers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Edit Order

    @Test func doneIsOneStepThatKeepsDiscsRenumbersAndUndoRestoresTheExactRows() async throws {
        let env = try makeEnv()
        let (id, tracks) = try await env.lib.album("Low Season", count: 4, numbers: [(1, 1), (1, 2), (2, 1), (2, 2)])
        let before = try await env.lib.joins.snapshot(albumID: id)
        let result = try await env.edits.setAlbumLayout(albumID: id, [
            (tracks[1], 1, 1), (tracks[0], 1, 2), (tracks[3], 2, 1), (tracks[2], 2, 2),
        ])
        #expect(result != nil)
        let rows = try await env.lib.joins.rows(of: id)
        #expect(rows.map(\.trackId) == [tracks[1], tracks[0], tracks[3], tracks[2]])
        #expect(rows.map(\.disc) == [1, 1, 2, 2], "setAlbumOrder would have flattened the discs")
        #expect(rows.map(\.trackNumber) == [1, 2, 1, 2])
        #expect(env.status.message?.text == "Reordered “Low Season”")
        #expect(env.manager.undoMenuItemTitle == "Undo Reorder “Low Season”")
        env.manager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await env.lib.joins.snapshot(albumID: id) == before)
        env.manager.redo()
        await env.undo.waitUntilIdle()
        #expect(try await env.lib.joins.rows(of: id).map(\.trackId) == [tracks[1], tracks[0], tracks[3], tracks[2]])
    }

    @Test func doneWithTheSameOrderLeavesNoStep() async throws {
        let env = try makeEnv()
        let (id, tracks) = try await env.lib.album("Low Season", count: 2, numbers: [(1, 1), (1, 2)])
        let result = try await env.edits.setAlbumLayout(albumID: id, [(tracks[0], 1, 1), (tracks[1], 1, 2)])
        #expect(result == nil)
        #expect(env.manager.undoMenuItemTitle == "Undo", "no step")
    }

    // MARK: Cover

    @Test func aCoverIsCopiedIntoTheCoversFolderAndUndoPutsTheOldPathBack() async throws {
        let env = try makeEnv()
        let (id, _) = try await env.lib.album("Low Season", count: 2)
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let refusal = await env.edits.setAlbumCover(.data(try png()), albumID: id, name: "Low Season", coversDirectory: folder)
        #expect(refusal == nil)
        let stored = try #require(try await env.lib.albums.fetch(id: id)?.coverPath)
        #expect(stored.hasPrefix("playlist-covers/album-\(id)-") && stored.hasSuffix(".png"))
        let file = try #require(PlaylistCoverService.safeFileURL(stored, in: folder))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(env.status.message?.text == "Set the cover of “Low Season”")
        #expect(env.manager.undoMenuItemTitle == "Undo Set Cover")
        env.manager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await env.lib.albums.fetch(id: id)?.coverPath == nil, "the previous cover (none) is back")
        env.manager.redo()
        await env.undo.waitUntilIdle()
        #expect(try await env.lib.albums.fetch(id: id)?.coverPath == stored)
    }

    @Test func somethingThatIsNotAnImageIsRefusedInWordsAndRegistersNothing() async throws {
        let env = try makeEnv()
        let (id, _) = try await env.lib.album("Low Season", count: 2)
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        let refusal = await env.edits.setAlbumCover(.file(text), albumID: id, name: "Low Season", coversDirectory: folder)
        #expect(refusal == "Couldn’t use “notes.txt” as a cover. Drop a PNG, JPEG or HEIC image.")
        #expect(try await env.lib.albums.fetch(id: id)?.coverPath == nil)
        #expect(env.manager.undoMenuItemTitle == "Undo")
        let none = await env.edits.setAlbumCover(.data(Data("x".utf8)), albumID: id, name: "Low Season", coversDirectory: folder)
        #expect(none == "Couldn’t use that image as a cover. Drop a PNG, JPEG or HEIC image.")
    }

    @Test func theCoverFileLivesInsideTheCoversFolderOnly() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: AlbumCoverFiles.Failure.noCoversFolder) {
            try AlbumCoverFiles.store(.data(try png()), albumID: 1, in: nil)
        }
        let reference = try AlbumCoverFiles.store(.data(try png()), albumID: 7, in: folder, stamp: "abc")
        #expect(reference == "playlist-covers/album-7-abc.png")
        let resolved = PlaylistCoverService.safeFileURL("playlist-covers/../../escape.png", in: folder)
        #expect(resolved?.deletingLastPathComponent().path == folder.path, "a path with .. can't leave the folder")
    }

    // MARK: Edition

    @Test func choosingAnEditionIsUndoableAndUndoOfTheFirstChoiceClearsIt() async throws {
        let env = try makeEnv()
        let (base, _) = try await env.lib.album("Low Season", count: 2)
        let (deluxe, _) = try await env.lib.album("Low Season (Deluxe)", count: 2)
        await env.edits.chooseEdition(base: base, selected: deluxe, edition: "Deluxe edition", albumTitle: "Low Season")
        #expect(try await env.lib.albums.fetchVariantPref(baseAlbumId: base) == deluxe)
        #expect(env.status.message?.text == "“Deluxe edition” is now the preferred edition of “Low Season”")
        #expect(env.manager.undoMenuItemTitle == "Undo Choose Edition")
        env.manager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await env.lib.albums.fetchVariantPref(baseAlbumId: base) == nil)
        env.manager.redo()
        await env.undo.waitUntilIdle()
        #expect(try await env.lib.albums.fetchVariantPref(baseAlbumId: base) == deluxe)
    }

    @Test func choosingTheEditionThatIsAlreadyPreferredChangesNothing() async throws {
        let env = try makeEnv()
        let (base, _) = try await env.lib.album("Low Season", count: 2)
        try await env.lib.albums.setVariantPref(baseAlbumId: base, selectedAlbumId: base)
        await env.edits.chooseEdition(base: base, selected: base, edition: "Standard edition", albumTitle: "Low Season")
        #expect(env.manager.undoMenuItemTitle == "Undo", "no step")
    }

    // MARK: Drops on a card and the dragged card

    private let context = DropContext(libraryID: "lib", isLibraryOpen: true, offlineVolumeName: nil)

    @Test func aCardTakesTracksAndImagesAndNothingElse() throws {
        let card = DropTarget.albumCard(id: 5, name: "Low Season")
        let tracks = TrackDragPayload(items: [TrackDragItem(trackId: 1, libraryId: "lib"), TrackDragItem(trackId: 2, libraryId: "lib")])
        #expect(DropRules.decide(.tracks(tracks), onto: card, context: context) == .addTracksToAlbum([1, 2], albumID: 5, albumName: "Low Season"))
        let image = Data([1, 2, 3])
        #expect(DropRules.decide(.imageData(image), onto: card, context: context) == .setAlbumCover(.data(image), albumID: 5, albumName: "Low Season"))
        let url = URL(fileURLWithPath: "/tmp/cover.png")
        let file = DroppedFile(url: url, kind: .image)
        #expect(DropRules.decide(.files([file]), onto: card, context: context) == .setAlbumCover(.file(url), albumID: 5, albumName: "Low Season"))
        let audio = DroppedFile(url: URL(fileURLWithPath: "/tmp/a.flac"), kind: .audio)
        #expect(DropRules.decide(.files([audio]), onto: card, context: context) == .refuse(nil))
        #expect(DropRules.decide(.playlists([PlaylistDragItem(playlistId: 1, libraryId: "lib")]), onto: card, context: context) == .refuse(nil))
        #expect(DropRules.decide(.link(URL(string: "https://example.com")!), onto: card, context: context) == .refuse(nil))
        let other = TrackDragPayload(items: [TrackDragItem(trackId: 1, libraryId: "other")])
        #expect(DropRules.decide(.tracks(other), onto: card, context: context) == .refuse(DropWords.otherLibrary), "never across libraries")
    }

    @Test func theCoverWellTakesImagesOnly() {
        let cover = DropTarget.albumCover(id: 5, name: "Low Season")
        let tracks = TrackDragPayload(items: [TrackDragItem(trackId: 1, libraryId: "lib")])
        #expect(DropRules.decide(.tracks(tracks), onto: cover, context: context) == .refuse(nil))
        let text = DroppedFile(url: URL(fileURLWithPath: "/tmp/a.txt"), kind: .other)
        #expect(DropRules.decide(.files([text]), onto: cover, context: context) == .refuse(DropWords.notACover(fileName: "a.txt")))
        #expect(DropRules.accepts(.imageData, on: cover, context: context))
        #expect(!DropRules.accepts(.tracks, on: cover, context: context))
        #expect(DropRules.accepts(.tracks, on: .albumCard(id: 1, name: "x"), context: context))
        #expect(!DropRules.accepts(.playlists, on: .albumCard(id: 1, name: "x"), context: context))
    }

    @Test func aDraggedAlbumCardIsAnAlbumItemThatStandsForNoTrackUntilExpanded() throws {
        let item = TrackDragItem.album(9, libraryId: "lib")
        #expect(item.isAlbum && !item.isFolder)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(TrackDragItem.self, from: data)
        #expect(decoded.albumId == 9)
        #expect(TrackDragPayload(items: [item]).trackIDs.isEmpty, "an unexpanded album item has no track ids")
        // Older payloads decode without the key.
        let old = try JSONDecoder().decode(TrackDragItem.self, from: Data(#"{"trackId":4}"#.utf8))
        #expect(old.albumId == nil && old.trackId == 4)
    }

    @Test func droppingTracksOnACardAddsThemAsOneUndoableStep() async throws {
        let env = try makeEnv()
        let (id, tracks) = try await env.lib.album("Low Season", count: 2)
        let extra = try await env.lib.db.write { db in
            try AlbumTracksMigrationTests.insertTrack(db, title: "Loose", album: "Other")
        }
        let added = try await env.edits.addTracks(toAlbum: id, trackIDs: [tracks[0], extra])
        #expect(added != nil)
        #expect(try await env.lib.joins.rows(of: id).count == 3)
        #expect(env.status.message?.text == "Added 1 track to “Low Season”")
    }
}
