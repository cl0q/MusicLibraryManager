import Foundation
import Testing
@testable import MLM

/// The Folders cells of the UC-DND matrix (W3-FOLD): a folder row (or a path-bar segment, or
/// the outline itself) takes Finder audio files and folders — imported through `Import Files or
/// Folder…` — and nothing else; a folder row drags as its tracks (D-FOLD-FOLDER-TO-PLAYLIST).
@Suite("Folders drag and drop (W3-FOLD)")
struct FolderDropTests {
    private let open = DropContext(libraryID: "lib", isLibraryOpen: true, offlineVolumeName: nil)
    private let offline = DropContext(libraryID: "lib", isLibraryOpen: true, offlineVolumeName: "Lexxar")
    private let folder = DropTarget.folderRow(path: "2026", name: "2026")

    private func files(_ names: [(String, DroppedFile.Kind)]) -> DropContent {
        .files(names.map { DroppedFile(url: URL(fileURLWithPath: "/Users/o/Desktop/\($0.0)"), kind: $0.1) })
    }

    @Test func aFolderRowTakesFinderFilesOnly() {
        #expect(DropRules.accepts(.files, on: folder, context: open))
        for kind in [DragKind.tracks, .playlists, .link, .imageData, .unknown] {
            #expect(!DropRules.accepts(kind, on: folder, context: open), "\(kind): no ring, not allowed")
        }
    }

    @Test func finderAudioFilesAndFoldersAreImported() {
        let decision = DropRules.decide(files([("a.flac", .audio), ("Set", .folder), ("notes.txt", .other)]), onto: folder, context: open)
        #expect(decision == .importFilesIntoLibrary([URL(fileURLWithPath: "/Users/o/Desktop/a.flac"),
                                                     URL(fileURLWithPath: "/Users/o/Desktop/Set")], folderPath: "2026"))
    }

    @Test func importingNeedsTheDrive() {
        #expect(DropRules.decide(files([("a.flac", .audio)]), onto: folder, context: offline)
                == .refuse(DropWords.cantImportOffline("Lexxar")))
    }

    @Test func otherFilesAreRefusedWithTheReason() {
        #expect(DropRules.decide(files([("notes.txt", .other)]), onto: folder, context: open)
                == .refuse(DropWords.notAudio(["notes.txt"])))
        #expect(DropRules.decide(files([("Warm-up.m3u8", .m3u)]), onto: folder, context: open)
                == .importM3U(URL(fileURLWithPath: "/Users/o/Desktop/Warm-up.m3u8"), playlistID: nil))
        #expect(DropRules.decide(files([("Main.mlibm", .libraryFile)]), onto: folder, context: open)
                == .openLibraryFile(URL(fileURLWithPath: "/Users/o/Desktop/Main.mlibm"), ignored: 0))
    }

    @Test func tracksAndPlaylistsDoNothingOnAFolder() {
        let tracks = DropContent.tracks(TrackDragPayload(items: [TrackDragItem(trackId: 1, libraryId: "lib")]))
        #expect(DropRules.decide(tracks, onto: folder, context: open) == .refuse(nil))
        #expect(DropRules.decide(.playlists([PlaylistDragItem(playlistId: 1, libraryId: "lib")]), onto: folder, context: open) == .refuse(nil))
    }

    // MARK: The folder row as a drag

    @Test func aFolderItemCarriesThePathAndSortButNotTheFile() throws {
        let item = TrackDragItem.folder("2026/Sets", libraryId: "lib", folderFilePath: "/Volumes/Lexxar/Music/2026/Sets",
                                        sort: TrackSortOrder(column: .added, ascending: false))
        #expect(item.isFolder && item.trackId == 0)
        #expect(item.fileURL?.path == "/Volumes/Lexxar/Music/2026/Sets", "outside MLM it is the folder")
        let decoded = try JSONDecoder().decode(TrackDragItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.folderPath == "2026/Sets")
        #expect(decoded.folderSort == "added:desc")
        #expect(decoded.filePath == nil, "the path leaves MLM only as the file URL")
        // An older build's payload decodes without the new keys.
        let old = try JSONDecoder().decode(TrackDragItem.self, from: Data(#"{"trackId":5,"libraryId":"lib"}"#.utf8))
        #expect(!old.isFolder && old.trackId == 5)
    }

    @Test func anUnexpandedFolderItemHasNoTrack() {
        let payload = TrackDragPayload(items: [
            TrackDragItem.folder("2026", libraryId: "lib", folderFilePath: nil, sort: nil),
            TrackDragItem(trackId: 7, libraryId: "lib"),
        ])
        #expect(payload.trackIDs == [7])
        #expect(payload.queueRows.map(\.trackId) == [7], "the Queue panel's own drop never queues track 0")
    }
}
