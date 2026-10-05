import Testing
import Foundation

@Suite("PlaylistTableReorderTests")
struct PlaylistTableReorderTests {

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

    // MARK: - PlaylistTable source-scan

    @Test func playlistTable_containsOnInsert() throws {
        // W2-A: the shared table accepts track drops where the context hooks `onInsert`.
        let table = try readSource("MLM/Views/TrackList/TrackListTable.swift")
        #expect(table.contains(".onInsert(of: configuration.onInsert == nil ? [] : [.trackDrag])"))
        #expect(try readSource("MLM/Views/Playlists/PlaylistTable.swift").contains("onInsert: { index, providers, rows in"))
    }

    @Test func playlistTable_containsPlaceTracks() throws {
        let src = try readSource("MLM/Views/Playlists/PlaylistTable.swift")
        #expect(src.contains("placeTracks("))
    }

    @Test func playlistTable_containsAccessibilityIdentifier() throws {
        // The playlist context of the shared table carries the id (W2-A).
        let configuration = try readSource("MLM/Views/TrackList/TrackListConfiguration.swift")
        #expect(configuration.contains("accessibilityID: \"playlist_track_table\""))
        #expect(try readSource("MLM/Views/Playlists/PlaylistTable.swift").contains("return .playlist("))
    }

    @Test func playlistTable_doesNotContainDropDestination() throws {
        let src = try readSource("MLM/Views/Playlists/PlaylistTable.swift")
        #expect(!src.contains(".dropDestination("))
    }

    // MARK: - PlaylistRepository source-scan

    @Test func playlistRepository_containsPlaceTracks() throws {
        let src = try readSource("MLM/Database/PlaylistRepository.swift")
        #expect(src.contains("func placeTracks(playlistId:"))
    }

    // MARK: - PlaylistDetailViewModel source-scan

    @Test func viewModel_containsPlaceTracks() throws {
        let src = try readSource("MLM/ViewModels/PlaylistDetailViewModel.swift")
        #expect(src.contains("func placeTracks(_ trackIDs: [Int64], at"))
    }

    @Test func viewModel_doesNotContainMoveTrack() throws {
        let src = try readSource("MLM/ViewModels/PlaylistDetailViewModel.swift")
        #expect(!src.contains("func moveTrack(from:"))
    }
}
