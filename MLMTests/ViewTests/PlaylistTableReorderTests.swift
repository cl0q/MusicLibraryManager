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
        let src = try readSource("MLM/Views/Playlists/PlaylistTable.swift")
        #expect(src.contains(".onInsert(of: [.trackDrag])"))
    }

    @Test func playlistTable_containsPlaceTracks() throws {
        let src = try readSource("MLM/Views/Playlists/PlaylistTable.swift")
        #expect(src.contains("placeTracks("))
    }

    @Test func playlistTable_containsAccessibilityIdentifier() throws {
        let src = try readSource("MLM/Views/Playlists/PlaylistTable.swift")
        #expect(src.contains("playlist_track_table"))
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
