import Testing
import Foundation
@testable import MLM

/// W5-1a, Shell and TrackList gaps G1 / G2 (UC-WIN-06), G4–G6 (UC-MOTION-03, UC-GLASS-04).
@Suite("W5GapShellTests")
struct W5GapShellTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("Window subtitle: library alone, or library and the place's count (G1)")
    func subtitleWording() {
        #expect(WindowSubtitle.text(library: "Music", placeCount: nil, fallback: nil) == "Music")
        #expect(WindowSubtitle.text(library: "Music", placeCount: "48 genres", fallback: nil) == "Music · 48 genres")
        #expect(WindowSubtitle.text(library: "Music", placeCount: "6 of 28 playlists", fallback: "28 playlists")
                == "Music · 6 of 28 playlists")
        #expect(WindowSubtitle.text(library: "Music", placeCount: nil, fallback: "12 tracks") == "Music · 12 tracks")
    }

    @Test("Albums, Genres, Playlists and the playlist page declare their window count (G1)")
    func placesDeclareCounts() throws {
        for path in ["MLM/Views/Albums/AlbumsView.swift", "MLM/Views/Genres/GenresView.swift",
                     "MLM/Views/Playlists/PlaylistsView.swift", "MLM/Views/Playlists/PlaylistDetailView.swift"] {
            #expect(try source(path).contains(".windowCount("), "\(path)")
        }
    }

    @Test("Folders uses the shared subtitle wording with a track count (G2)")
    func foldersSubtitle() throws {
        let text = try source("MLM/Views/Folders/FoldersView.swift")
        #expect(text.contains("WindowSubtitle.text("))
        #expect(!text.contains(".navigationSubtitle(LibraryFooter"))
    }

    @Test("The playing glyph honours Reduce Motion in both cells (G4, G5)")
    func glyphReduceMotion() throws {
        let text = try source("MLM/Views/TrackList/TrackCell.swift")
        #expect(text.contains("accessibilityReduceMotion"))
        #expect(text.components(separatedBy: "&& !reduceMotion").count - 1 >= 2)
    }

    @Test("Track tables, Genres grid and Folders outline have the soft top scroll-edge (G6)")
    func softTopEdge() throws {
        for path in ["MLM/Views/TrackList/TrackListTable.swift", "MLM/Views/Genres/GenresView.swift",
                     "MLM/Views/Folders/FolderOutlineTable.swift"] {
            #expect(try source(path).contains(".scrollEdgeEffectStyle(.soft, for: .top)"), "\(path)")
        }
    }
}
