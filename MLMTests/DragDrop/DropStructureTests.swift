import Foundation
import Testing
@testable import MLM

/// Structure of the drag & drop code (W2-H): drops change data only through the undoable
/// edits (UC-UNDO-08), no pulsing outline is left, the loader's pure parts, the import helpers.
@Suite("Drag & drop structure")
struct DropStructureTests {
    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Repository writes a drop handler must never call itself — each has an undoable edit.
    private static let directWrites = [
        "appendTracks(playlistId", "addTracks(playlistId", "placeTracks(playlistId", "setCoverPath(",
        "addTrack(profileId", "addPlaylist(profileId", "setCustomCover(", "addTracks(_ trackIds",
        ".addPlaylists([", "syncViewModel?.addTracks", "playlistRepository",
    ]

    @Test func noDropHandlerBypassesTheUndoCenter() throws {
        let handlers = [
            "MLM/Services/DragDrop/DropPerformer.swift",
            "MLM/Services/DragDrop/DropRules.swift",
            "MLM/Services/DragDrop/DropLoader.swift",
            "MLM/Views/DragDrop/DropTargetModifier.swift",
            "MLM/Views/Playlists/PlaylistCard.swift",
            "MLM/Views/Playlists/PlaylistTable.swift",
        ]
        for path in handlers {
            let text = try source(path)
            for write in Self.directWrites {
                #expect(!text.contains(write), "\(path) calls \(write) — use the undoable edit (ShellEdits)")
            }
        }
        // The drop edits each register one step.
        let edits = try source("MLM/Views/Shell/ShellEdits.swift")
        let drops = try #require(edits.components(separatedBy: "// MARK: - Drops (W2-H, DEC-040)").last)
        for function in ["func placeTracks(", "func newPlaylist(named", "func addTracks(_ trackIDs: [Int64], toSyncProfile",
                         "func addPlaylists(", "func setCover("] {
            let body = try #require(drops.components(separatedBy: function).dropFirst().first, "\(function)")
            let next = body.components(separatedBy: "\n    func ").first ?? body
            #expect(next.contains("undo.perform(") || next.contains("performKeeping("), "\(function) registers an undo step")
        }
    }

    @Test func thePulsingSpringLoadIsGone() throws {
        #expect(!FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("MLM/Views/Shared/SpringLoadableHover.swift").path))
        let modifier = try source("MLM/Views/DragDrop/DropTargetModifier.swift")
        #expect(!modifier.contains("repeatForever"))
        #expect(!modifier.contains("Timer.scheduledTimer"))
        let card = try source("MLM/Views/Playlists/PlaylistCard.swift")
        #expect(!card.contains("Timer.scheduledTimer"))
        #expect(!card.contains(".onDrop("))
    }

    @Test func theSidebarRowsAreDropTargetsAndPlaylistsDrag() throws {
        let sidebar = try source("MLM/Views/Sidebar/SidebarView.swift")
        #expect(sidebar.contains(".dropTarget(\n                        .sidebarPlaylist(id: id, name: playlist.name)"))
        #expect(sidebar.contains("isShown: navigation.selection == .playlist(id)"))
        #expect(sidebar.contains(".dropTarget(.syncProfile(id: id, name: profile.name))"))
        #expect(sidebar.contains(".dropTarget(destination == .allPlaylists ? .playlistsSection : .fixedRow)"))
        #expect(sidebar.contains(".draggable(PlaylistDragItem("))
        // A new playlist only from the Playlists header, All Playlists and the empty area below
        // the last row — never from the Library, Inbox or Sync headers (coordinator decision f).
        #expect(sidebar.components(separatedBy: ".dropTarget(.playlistsSection)").count - 1 == 2,
                "the Playlists header and the empty area")
        #expect(sidebar.contains("SidebarEmptyDropArea()"))
        #expect(!sidebar.contains(".listStyle(.sidebar)\n        // The empty area"), "no List-wide target")
    }

    @Test func thePlayerCoverDragsAndStillOpensTheLargeCover() throws {
        // Coordinator decision (a): UC-TB-06 — draggable as the track, the click keeps the popover.
        let player = try source("MLM/Views/Player/PlayerBar.swift")
        let cover = try #require(player.components(separatedBy: "private struct PlayerCover: View {").last)
            .components(separatedBy: "private struct LargeCoverPopover").first ?? ""
        #expect(cover.contains("showsLargeCover.toggle()"))
        #expect(cover.contains(".draggable(item)"))
        #expect(cover.contains(".popover(isPresented: $showsLargeCover"))
    }

    // MARK: Loader

    @Test func fileURLsAreReadFromThePasteboardValue() {
        let url = URL(fileURLWithPath: "/Users/o/Desktop/a b.mp3")
        #expect(DropLoader.fileURL(from: url.dataRepresentation) == url)
        #expect(DropLoader.fileURL(from: Data(url.absoluteString.utf8)) == url)
        #expect(DropLoader.fileURL(from: Data("https://example.com/a.mp3".utf8)) == nil)
    }

    @Test func onlyAWebLinkIsALink() {
        #expect(DropLoader.webLink(fromText: " https://soundcloud.com/a/b \n")?.absoluteString == "https://soundcloud.com/a/b")
        #expect(DropLoader.webLink(fromText: "see https://soundcloud.com/a") == nil)
        #expect(DropLoader.webLink(fromText: "file:///etc/passwd") == nil)
        #expect(DropLoader.webLink(fromText: "hello") == nil)
        #expect(DropLoader.webLink(fromURLData: Data("https://youtube.com/watch?v=1".utf8)) != nil)
        #expect(DropLoader.webLink(fromURLData: URL(fileURLWithPath: "/a").dataRepresentation) == nil)
    }

    // MARK: Import by drop

    @Test func droppedFoldersAreReadForTheirAudioFilesInDropOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DropStructureTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let inner = folder.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for name in ["b.mp3", "a.flac", "cover.jpg"] { try Data([0]).write(to: inner.appendingPathComponent(name)) }
        let loose = folder.appendingPathComponent("z.m4a")
        let notes = folder.appendingPathComponent("notes.txt")
        try Data([0]).write(to: loose)
        try Data([0]).write(to: notes)

        let files = ShellActions.audioFiles(in: [loose, inner, notes, loose])
        #expect(files.map(\.lastPathComponent) == ["z.m4a", "a.flac", "b.mp3"])
    }

    @Test func importedTracksComeBackInDropOrder() {
        func track(_ id: Int64, _ path: String) -> Track {
            var track = Track(artist: "A", album: "B", title: "T", format: "mp3", originalPath: path)
            track.id = id
            return track
        }
        let tracks = [track(1, "/m/b.mp3"), track(2, "/m/a.mp3")]
        #expect(ShellActions.orderedIDs(of: tracks, paths: ["/m/a.mp3", "/m/x.mp3", "/m/b.mp3", "/m/a.mp3"]) == [2, 1])
    }

    // MARK: Spring-loading timing

    @Test func springLoadingFollowsTheSystemSetting() throws {
        let defaults = try #require(UserDefaults(suiteName: "DropStructureTests-\(UUID().uuidString)"))
        #expect(SpringLoading.delay(defaults) == SpringLoading.defaultDelay)
        defaults.set(1.2, forKey: "com.apple.springing.delay")
        #expect(SpringLoading.delay(defaults) == 1.2)
        defaults.set(false, forKey: "com.apple.springing.enabled")
        #expect(SpringLoading.delay(defaults) == nil, "off in System Settings: never")
    }
}
