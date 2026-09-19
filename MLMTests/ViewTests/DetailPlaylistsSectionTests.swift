import Testing
import Foundation

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

    // MARK: - MetadataPanel source-scan

    @Test func metadataPanel_containsGeneralTabContent() throws {
        let src = try readSource("MLM/Views/TrackDetail/MetadataPanel.swift")
        #expect(src.contains("private var generalTabContent"))
    }

    @Test func metadataPanel_containsPlaylistsSection() throws {
        let src = try readSource("MLM/Views/TrackDetail/MetadataPanel.swift")
        #expect(src.contains("playlistsSection"))
    }

    @Test func metadataPanel_containsAccessibilityIdentifiers() throws {
        let src = try readSource("MLM/Views/TrackDetail/MetadataPanel.swift")
        #expect(src.contains("detail_playlists_section"))
        #expect(src.contains("detail_playlist_row"))
        #expect(src.contains("detail_playlist_remove_button"))
        #expect(src.contains("detail_playlists_empty"))
    }

    @Test func metadataPanel_containsEmptyStateText() throws {
        let src = try readSource("MLM/Views/TrackDetail/MetadataPanel.swift")
        #expect(src.contains("Not in any playlist"))
    }

    @Test func metadataPanel_containsTrackPlaylistsState() throws {
        let src = try readSource("MLM/Views/TrackDetail/MetadataPanel.swift")
        #expect(src.contains("trackPlaylists"))
    }

    @Test func metadataPanel_containsFetchAndRemove() throws {
        let src = try readSource("MLM/Views/TrackDetail/MetadataPanel.swift")
        #expect(src.contains("fetchPlaylists(forTrackId:"))
        #expect(src.contains("removeTrack(playlistId:"))
    }

    @Test func metadataPanel_containsXmarkIcon() throws {
        let src = try readSource("MLM/Views/TrackDetail/MetadataPanel.swift")
        #expect(src.contains("xmark.circle.fill"))
    }

    @Test func metadataPanel_preservesExistingEditableRows() throws {
        let src = try readSource("MLM/Views/TrackDetail/MetadataPanel.swift")
        #expect(src.contains("editableRow(label: \"Title\""))
        #expect(src.contains("editableRow(label: \"Artist\""))
        #expect(src.contains("editableRow(label: \"Album Artist\""))
        #expect(src.contains("editableRow(label: \"Album\""))
        #expect(src.contains("editableRow(label: \"Genre\""))
        #expect(src.contains("editableRow(label: \"Year\""))
    }

    @Test func metadataPanel_noConfirmationDialog() throws {
        let src = try readSource("MLM/Views/TrackDetail/MetadataPanel.swift")
        #expect(!src.contains("confirmationDialog"))
    }

    // MARK: - PlaylistRepository source-scan

    @Test func playlistRepository_containsFetchPlaylistsForTrackId() throws {
        let src = try readSource("MLM/Database/PlaylistRepository.swift")
        #expect(src.contains("func fetchPlaylists(forTrackId trackId: Int64) async throws -> [Playlist]"))
    }
}
