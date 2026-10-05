import Testing
import Foundation
@testable import MLM

/// W1-2 review B1: Remove from Library… is always confirmed, worded for what happens
/// (A-TRACK-REMOVE, UC-SHEET-12…15, UC-KEY-18), on both routes.
@Suite("Remove from Library confirmation (W1-2 review)")
struct LibraryRemovalConfirmationTests {

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func localTracksMoveToTheTrash() {
        let one = LibraryRemovalConfirmation.make(trackCount: 1, fileCount: 1)
        #expect(one.title == "Remove 1 track from the library?")
        #expect(one.message == "Its file moves to the Trash and it is removed from its playlists and sync profiles. You can put the file back from the Trash.")
        #expect(one.confirmTitle == "Move to Trash")
        let many = LibraryRemovalConfirmation.make(trackCount: 14, fileCount: 14)
        #expect(many.title == "Remove 14 tracks from the library?")
        #expect(many.message == "Their files move to the Trash and they are removed from their playlists and sync profiles. You can put the files back from the Trash.")
        #expect(many.confirmTitle == "Move to Trash")
    }

    @Test func tracksWithoutFilesAreStillConfirmed() {
        let one = LibraryRemovalConfirmation.make(trackCount: 1, fileCount: 0)
        #expect(one.title == "Remove 1 track from the library?")
        #expect(one.message == "It has no file, so nothing moves to the Trash, and it is removed from its playlists and sync profiles.")
        #expect(one.confirmTitle == "Remove from Library")
        let many = LibraryRemovalConfirmation.make(trackCount: 3, fileCount: 0)
        #expect(many.message == "They have no files, so nothing moves to the Trash, and they are removed from their playlists and sync profiles.")
        #expect(!many.message.contains("put the file"), "no Trash sentence without files")
    }

    @Test func mixedSelectionCountsTheFiles() {
        let mixed = LibraryRemovalConfirmation.make(trackCount: 5, fileCount: 2)
        #expect(mixed.title == "Remove 5 tracks from the library?")
        #expect(mixed.message == "The files of 2 tracks move to the Trash, and all 5 are removed from their playlists and sync profiles. You can put the files back from the Trash.")
        #expect(mixed.confirmTitle == "Move to Trash")
        #expect(LibraryRemovalConfirmation.make(trackCount: 2, fileCount: 1).message.hasPrefix("The file of 1 track moves"))
    }

    @Test func copyFollowsTheRules() {
        for (count, files) in [(1, 0), (1, 1), (4, 0), (4, 4), (4, 1)] {
            let alert = LibraryRemovalConfirmation.make(trackCount: count, fileCount: files)
            #expect(alert.title.hasSuffix("?"))
            #expect(!alert.message.contains("cannot be undone") && !alert.title.contains("Are you sure"))
            #expect(alert.message.contains("playlists and sync profiles"), "the tracks leave their playlists")
        }
    }

    /// Both routes ask through the one center; Cancel is the default button, the destructive
    /// button has the destructive role (DEC-052).
    @Test func bothRoutesUseTheOneConfirmation() throws {
        let actions = try source("MLM/App/Commands/TrackCommandActions.swift")
        let request = try #require(actions.range(of: "static func request(_ tracks: [Track], container: DependencyContainer)"))
        let next = try #require(actions.range(of: "static func remove(", range: request.upperBound..<actions.endIndex))
        let body = String(actions[request.upperBound..<next.lowerBound])
        #expect(body.contains("LibraryRemovalCenter.shared.ask(tracks)"))
        #expect(!body.contains("remove("), "nothing is removed before the answer")
        #expect(actions.contains("Button(request.confirmation.confirmTitle, role: .destructive)"))
        #expect(actions.contains("Button(\"Cancel\", role: .cancel)"))
        #expect(actions.contains(".keyboardShortcut(.defaultAction)"))
        // W2-A: the track menu (`TrackMenu` → `TrackListActions`) asks through the same path.
        let menuActions = try source("MLM/Views/TrackList/TrackListActions.swift")
        #expect(menuActions.contains("TrackCommandActions.removeFromLibrary(rows.map(\\.track), container: container)"))
        #expect(try source("MLM/Views/TrackList/TrackMenu.swift").contains("actions.removeFromLibrary(rows)"))
        #expect(!menuActions.contains("NSAlert"), "the context menu has no confirmation of its own")
        let content = try source("MLM/Views/ContentView/ContentView.swift")
        #expect(content.contains(".modifier(LibraryRemovalAlert())"))
    }
}
