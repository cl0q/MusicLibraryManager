import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MLM

/// The UC-DND matrix as pure functions (W2-H): for every implemented cell, whether the target
/// takes the drag while it hovers (ring + copy cursor, or no ring + not allowed) and what the
/// drop does — or the refusal and its sentence.
@Suite("Drop rules (UC-DND matrix)")
struct DropRulesTests {
    private let open = DropContext(libraryID: "lib", isLibraryOpen: true, offlineVolumeName: nil)
    private let offline = DropContext(libraryID: "lib", isLibraryOpen: true, offlineVolumeName: "Lexxar")
    private let launch = DropContext(libraryID: nil, isLibraryOpen: false, offlineVolumeName: nil)

    private let warmUp = DropTarget.sidebarPlaylist(id: 1, name: "Warm-up")
    private let profile = DropTarget.syncProfile(id: 7, name: "iPod Classic")
    private let table = DropTarget.playlistTable(id: 1, name: "Warm-up", sortedBy: nil)
    private let cover = DropTarget.playlistCover(id: 1, name: "Warm-up")
    private let card = DropTarget.playlistCard(id: 1, name: "Warm-up")

    private func tracks(_ ids: [Int64], library: String? = "lib", from playlist: Int64? = nil) -> DropContent {
        .tracks(TrackDragPayload(items: ids.map { TrackDragItem(trackId: $0, sourcePlaylistId: playlist, libraryId: library) }))
    }

    private func files(_ names: [(String, DroppedFile.Kind)]) -> DropContent {
        .files(names.map { DroppedFile(url: URL(fileURLWithPath: "/Users/o/Desktop/\($0.0)"), kind: $0.1) })
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/Users/o/Desktop/\(name)") }

    // MARK: Hover kinds

    @Test func theHoverKindComesFromThePasteboardTypes() {
        func kind(_ types: [UTType]) -> DragKind { DropRules.hoverKind { type in types.contains { $0.conforms(to: type) } } }
        // A track drag also carries its file URL: the ids win.
        #expect(kind([.draggedTracks, .url, .fileURL]) == .tracks)
        #expect(kind([.legacyTrackDrag]) == .tracks)
        #expect(kind([.draggedPlaylist]) == .playlists)
        #expect(kind([.fileURL]) == .files)
        #expect(kind([.png]) == .imageData)
        #expect(kind([.url]) == .link)
        #expect(kind([.utf8PlainText]) == .link)
        #expect(kind([.data]) == .unknown)
    }

    // MARK: Hover: ring or not allowed (every column)

    @Test func everyTargetTakesWhatTheMatrixSays() {
        let matrix: [(DropTarget, Set<DragKind>)] = [
            (warmUp, [.tracks, .playlists, .files, .link]),
            (.playlistsSection, [.tracks, .playlists, .files, .link]),
            (.playlistFolder(id: 9, name: "Sets"), [.tracks, .playlists, .files]),
            (.playlistOrder(folderID: nil, before: nil), [.playlists]),
            (profile, [.tracks, .playlists]),
            (.fixedRow, [.files]),
            (self.table, [.tracks, .playlists, .files, .link]),
            (.player, [.tracks, .playlists]),
            (cover, [.files, .imageData]),
            (card, [.tracks, .playlists, .files, .imageData, .link]),
            (.window, [.files, .link]),
        ]
        let kinds: [DragKind] = [.tracks, .playlists, .files, .imageData, .link, .unknown]
        for (target, accepted) in matrix {
            for kind in kinds {
                #expect(DropRules.accepts(kind, on: target, context: open) == accepted.contains(kind), "\(target) × \(kind)")
            }
        }
    }

    @Test func launchStatesTakeOnlyALibraryFileOnTheWindow() {
        #expect(DropRules.accepts(.files, on: .window, context: launch))
        #expect(!DropRules.accepts(.link, on: .window, context: launch))
        #expect(!DropRules.accepts(.tracks, on: warmUp, context: launch))
        #expect(DropRules.decide(files([("Laptop.mlibm", .libraryFile)]), onto: .window, context: launch)
                == .openLibraryFile(url("Laptop.mlibm"), ignored: 0))
        #expect(DropRules.decide(files([("a.mp3", .audio)]), onto: .window, context: launch) == .refuse(nil))
    }

    @Test func springLoadingOnlyOnPlaylistsForTracksAndNeverOnTheShownOne() {
        #expect(DropRules.springLoads(.tracks, on: warmUp, isShown: false))
        #expect(DropRules.springLoads(.tracks, on: card, isShown: false))
        #expect(!DropRules.springLoads(.tracks, on: warmUp, isShown: true), "the selected row never re-opens (W1 fix)")
        #expect(!DropRules.springLoads(.files, on: warmUp, isShown: false))
        #expect(!DropRules.springLoads(.tracks, on: .fixedRow, isShown: false), "views aren't containers")
        #expect(!DropRules.springLoads(.tracks, on: profile, isShown: false))
    }

    // MARK: Tracks (row "Tracks")

    @Test func tracksDoWhatEachTargetSays() {
        #expect(DropRules.decide(tracks([3, 1, 3]), onto: warmUp, context: open) == .appendTracks([3, 1], playlistID: 1, playlistName: "Warm-up"))
        #expect(DropRules.decide(tracks([3, 1]), onto: .playlistsSection, context: open) == .newPlaylist([3, 1]))
        #expect(DropRules.decide(tracks([3]), onto: profile, context: open) == .addTracksToSyncProfile([3], profileID: 7, profileName: "iPod Classic"))
        let payload = TrackDragPayload(items: [TrackDragItem(trackId: 3, libraryId: "lib")])
        #expect(DropRules.decide(.tracks(payload), onto: table, context: open) == .placeTracks(payload, playlistID: 1, playlistName: "Warm-up"))
        #expect(DropRules.decide(.tracks(payload), onto: .player, context: open) == .playNext(payload))
        #expect(DropRules.decide(tracks([3]), onto: card, context: open) == .appendTracks([3], playlistID: 1, playlistName: "Warm-up"))
        for target in [DropTarget.fixedRow, cover, .window] {
            #expect(DropRules.decide(tracks([3]), onto: target, context: open) == .refuse(nil), "\(target)")
        }
    }

    @Test func tracksWorkWhileTheDriveIsAway() {
        // P6: building playlists, sync profiles and the queue doesn't need the files.
        #expect(DropRules.decide(tracks([3]), onto: warmUp, context: offline) == .appendTracks([3], playlistID: 1, playlistName: "Warm-up"))
        #expect(DropRules.decide(tracks([3]), onto: profile, context: offline) == .addTracksToSyncProfile([3], profileID: 7, profileName: "iPod Classic"))
        #expect(DropRules.accepts(.tracks, on: .player, context: offline))
    }

    @Test func tracksFromAnotherLibraryAreRefused() {
        let decision = DropRules.decide(tracks([3], library: "other"), onto: warmUp, context: open)
        #expect(decision == .refuse(DropWords.otherLibrary))
        #expect(DropRules.decide(.playlists([PlaylistDragItem(playlistId: 2, libraryId: "other")]), onto: profile, context: open)
                == .refuse(DropWords.otherLibrary))
        // A drag from a build before W2-H has no library id: this library's.
        #expect(DropRules.decide(tracks([3], library: nil), onto: warmUp, context: open) == .appendTracks([3], playlistID: 1, playlistName: "Warm-up"))
    }

    // MARK: Playlists (row "Playlist")

    @Test func playlistsDoWhatEachTargetSays() {
        let two = DropContent.playlists([PlaylistDragItem(playlistId: 2, libraryId: "lib"), PlaylistDragItem(playlistId: 1, libraryId: "lib")])
        #expect(DropRules.decide(two, onto: warmUp, context: open) == .appendPlaylists([2], playlistID: 1, playlistName: "Warm-up"))
        #expect(DropRules.decide(.playlists([PlaylistDragItem(playlistId: 1)]), onto: warmUp, context: open) == .refuse(nil),
                "a playlist onto itself does nothing")
        #expect(DropRules.decide(two, onto: profile, context: open) == .addPlaylistsToSyncProfile([2, 1], profileID: 7, profileName: "iPod Classic"))
        #expect(DropRules.decide(two, onto: table, context: open) == .placePlaylists([2], playlistID: 1, playlistName: "Warm-up"))
        #expect(DropRules.decide(two, onto: .player, context: open) == .playNextPlaylists([2, 1]))
        // W3-PL: the header / empty area moves playlists to the top level, at the end.
        #expect(DropRules.decide(two, onto: .playlistsSection, context: open)
                == .movePlaylistItemsToTop([.playlist(2), .playlist(1)]))
    }

    // MARK: Finder files and folders

    @Test func audioFilesAndFoldersImport() {
        let dropped = files([("Road trip", .folder), ("a.mp3", .audio), ("notes.txt", .other)])
        let urls = [url("Road trip"), url("a.mp3")]
        #expect(DropRules.decide(dropped, onto: .window, context: open) == .importFiles(urls))
        #expect(DropRules.decide(dropped, onto: .fixedRow, context: open) == .importFiles(urls))
        #expect(DropRules.decide(dropped, onto: warmUp, context: open) == .importFilesAndAdd(urls, playlistID: 1, playlistName: "Warm-up"))
        #expect(DropRules.decide(dropped, onto: table, context: open) == .importFilesAndPlace(urls, playlistID: 1, playlistName: "Warm-up"))
        #expect(DropRules.decide(dropped, onto: .playlistsSection, context: open) == .importFilesAsNewPlaylist(urls, name: nil))
        #expect(DropRules.decide(files([("Road trip", .folder)]), onto: .playlistsSection, context: open)
                == .importFilesAsNewPlaylist([url("Road trip")], name: "Road trip"), "a folder names the new playlist")
        #expect(DropRules.decide(files([("a.mp3", .audio)]), onto: card, context: open)
                == .importFilesAndAdd([url("a.mp3")], playlistID: 1, playlistName: "Warm-up"))
    }

    @Test func importNeedsTheLibraryFolder() {
        let decision = DropRules.decide(files([("a.mp3", .audio)]), onto: .window, context: offline)
        #expect(decision == .refuse("Can’t import — “Lexxar” is not connected"))
        #expect(DropRules.decide(files([("a.mp3", .audio)]), onto: warmUp, context: offline) == .refuse(DropWords.cantImportOffline("Lexxar")))
    }

    @Test func filesMLMCantUseAreRefusedWithTheReason() {
        #expect(DropRules.decide(files([("notes.txt", .other)]), onto: .window, context: open)
                == .refuse("Can’t import “notes.txt” — it isn’t an audio file or a folder"))
        #expect(DropRules.decide(files([("a.txt", .other), ("b.pdf", .other)]), onto: .fixedRow, context: open)
                == .refuse("Can’t import these 2 files — none is an audio file or a folder"))
    }

    @Test func anM3UShowsItsPreview() {
        let m3u = files([("Old iPod.m3u8", .m3u)])
        #expect(DropRules.decide(m3u, onto: warmUp, context: open) == .importM3U(url("Old iPod.m3u8"), playlistID: 1))
        #expect(DropRules.decide(m3u, onto: table, context: open) == .importM3U(url("Old iPod.m3u8"), playlistID: 1))
        #expect(DropRules.decide(m3u, onto: .playlistsSection, context: open) == .importM3U(url("Old iPod.m3u8"), playlistID: nil))
        #expect(DropRules.decide(m3u, onto: .window, context: open) == .importM3U(url("Old iPod.m3u8"), playlistID: nil))
        #expect(DropRules.decide(m3u, onto: profile, context: open) == .refuse(nil))
    }

    @Test func aLibraryFileOpensTheLibraryAndNamesWhatIsIgnored() {
        let dropped = files([("Laptop.mlibm", .libraryFile), ("a.mp3", .audio)])
        #expect(DropRules.decide(dropped, onto: .window, context: open) == .openLibraryFile(url("Laptop.mlibm"), ignored: 1))
        #expect(DropRules.decide(dropped, onto: warmUp, context: open) == .openLibraryFile(url("Laptop.mlibm"), ignored: 1))
        #expect(DropWords.ignoredWithLibrary(1) == "Opening the library — 1 other file was ignored")
    }

    // MARK: Images and covers

    @Test func anImageSetsTheCoverAndAnythingElseIsRefusedInPlace() {
        #expect(DropRules.decide(files([("art.png", .image)]), onto: cover, context: open)
                == .setCover(.file(url("art.png")), playlistID: 1, playlistName: "Warm-up"))
        #expect(DropRules.decide(.imageData(Data([1])), onto: cover, context: open) == .setCover(.data(Data([1])), playlistID: 1, playlistName: "Warm-up"))
        #expect(DropRules.decide(files([("notes.txt", .other)]), onto: cover, context: open)
                == .refuse("Couldn’t use “notes.txt” as a cover. Drop a PNG, JPEG or HEIC image."))
        // A card: images set its cover, a useless file is a refused cover drop, audio is added.
        #expect(DropRules.decide(files([("art.jpg", .image)]), onto: card, context: open)
                == .setCover(.file(url("art.jpg")), playlistID: 1, playlistName: "Warm-up"))
        #expect(DropRules.decide(files([("notes.txt", .other)]), onto: card, context: open)
                == .refuse(DropWords.notACover(fileName: "notes.txt")))
        #expect(DropRules.decide(.imageData(Data([1])), onto: warmUp, context: open) == .refuse(nil))
        #expect(DropWords.notACover(fileName: nil) == "Couldn’t use that image as a cover. Drop a PNG, JPEG or HEIC image.")
    }

    // MARK: Links

    @Test func aLinkGoesToAddFromLink() {
        let link = URL(string: "https://soundcloud.com/a/b")!
        #expect(DropRules.decide(.link(link), onto: .window, context: open) == .openLink(link, playlistID: nil))
        #expect(DropRules.decide(.link(link), onto: .playlistsSection, context: open) == .openLink(link, playlistID: nil))
        #expect(DropRules.decide(.link(link), onto: warmUp, context: open) == .openLink(link, playlistID: 1))
        #expect(DropRules.decide(.link(link), onto: table, context: open) == .openLink(link, playlistID: 1))
        #expect(DropRules.decide(.link(link), onto: profile, context: open) == .refuse(nil))
        #expect(DropRules.decide(.link(link), onto: .player, context: open) == .refuse(nil))
    }

    // MARK: Classifying dropped files

    @Test func droppedFilesAreClassifiedByNameAndFolderFlag() {
        func kind(_ name: String, folder: Bool = false) -> DroppedFile.Kind {
            DroppedFile.kind(of: URL(fileURLWithPath: "/x/\(name)"), isDirectory: folder)
        }
        #expect(kind("Main Library.mlibm", folder: true) == .libraryFile)
        #expect(kind("Sets", folder: true) == .folder)
        #expect(kind("list.m3u") == .m3u)
        #expect(kind("list.M3U8") == .m3u)
        #expect(kind("cover.jpeg") == .image)
        #expect(kind("cover.heic") == .image)
        #expect(kind("song.mp3") == .audio)
        #expect(kind("song.flac") == .audio)
        #expect(kind("song.m4a") == .audio)
        #expect(kind("notes.txt") == .other)
    }

    // MARK: Words

    @Test func theSentencesFollowTheCopyRules() {
        let sentences = [
            DropWords.otherLibrary, DropWords.notACover(fileName: "a.txt"), DropWords.notAudio(["a.txt"]),
            DropWords.cantImportOffline("Lexxar"), DropWords.insertedMessage(added: 2, moved: 1, position: 4, playlist: "Warm-up"),
            DropWords.reorderedMessage(count: 3, position: 1, playlist: "Warm-up"), DropWords.coverSetMessage("Warm-up"),
            DropWords.addedToProfile(tracks: 3, alreadyPresent: 1, profile: "iPod Classic"),
            DropWords.addedPlaylistsToProfile(names: ["Warm-up"], profile: "iPod Classic"),
            DropWords.importTitle(files: 4, folderName: nil, playlist: "Road trip 2026"),
            DropWords.cantCopyOffline("Lexxar"),
        ]
        for sentence in sentences {
            #expect(!sentence.contains("'") && !sentence.contains("\""), "typographic quotes only: \(sentence)")
            #expect(!sentence.contains("Error") && !sentence.contains("Song"), "glossary words: \(sentence)")
        }
        #expect(DropWords.insertedMessage(added: 2, moved: 0, position: 4, playlist: "Warm-up") == "Added 2 tracks to “Warm-up” at position 4")
        #expect(DropWords.reorderedMessage(count: 3, position: 1, playlist: "Warm-up") == "Moved 3 tracks to position 1 in “Warm-up”")
        #expect(DropWords.addedToProfile(tracks: 3, alreadyPresent: 0, profile: "iPod Classic") == "Added 3 tracks to “iPod Classic”")
        #expect(DropWords.addedPlaylistsToProfile(names: ["Warm-up"], profile: "iPod Classic") == "Added “Warm-up” to “iPod Classic”")
        #expect(DropWords.importTitle(files: 4, folderName: nil, playlist: "Road trip 2026") == "Import 4 files into “Road trip 2026”")
        #expect(DropWords.importTitle(files: 9, folderName: "Sets", playlist: nil) == "Scan “Sets”")
        #expect(DropWords.reorderActionName("Warm-up") == "Reorder “Warm-up”")
        #expect(DropWords.addActionName("Warm-up") == "Add to “Warm-up”")
        #expect(DropWords.cantCopyOffline("Lexxar") == "Can’t copy files — “Lexxar” is not connected")
    }
}
