import Testing
import Foundation

/// Info ▸ Details ▸ In playlists (P-INSPECTOR-GENERAL.E07, W2-E): remove is undoable and takes
/// exactly the selection's rows; no confirmation (UC-UNDO-06).
@Suite("DetailPlaylistsSectionTests")
struct DetailPlaylistsSectionTests {

    private static var repoRoot: URL {
        let url = URL(fileURLWithPath: #filePath)
        return url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static let detailsPath = "MLM/Views/Inspector/InspectorDetailsTab.swift"

    @Test func inPlaylistsSectionListsMembershipOfTheSelection() throws {
        let src = try readSource(Self.detailsPath)
        #expect(src.contains("Section(\"In playlists\")"))
        #expect(src.contains("memberships(trackIDs: trackIDs)"))
        #expect(src.contains("Not in any playlist."))
    }

    @Test func removeIsUndoableAndExact() throws {
        let src = try readSource(Self.detailsPath)
        #expect(src.contains("PlaylistTrackRemoval.remove(Set(trackIDs), fromPlaylist: membership.playlistID"),
                "exact rows of the selection, one undo step (W2-F contract)")
        #expect(!src.contains("removeTrack(playlistId:"), "the old non-undoable removal is gone")
        #expect(!src.contains("confirmationDialog"))
        #expect(src.contains(".help(\"Remove from “\\(membership.name)”\")"))
    }

    @Test func addToPlaylistReplacesTheOldFooter() throws {
        let src = try readSource(Self.detailsPath)
        #expect(src.contains("Menu(\"Add to Playlist\")"))
        #expect(src.contains("shell?.addToPlaylist(id, trackIDs: trackIDs)"))
        #expect(!src.contains("999000"), "no fixed position string (inventory P-INSPECTOR pain point)")
    }

    // MARK: - PlaylistRepository source-scan

    @Test func playlistRepository_containsFetchPlaylistsForTrackId() throws {
        let src = try readSource("MLM/Database/PlaylistRepository.swift")
        #expect(src.contains("func fetchPlaylists(forTrackId trackId: Int64) async throws -> [Playlist]"))
    }
}
