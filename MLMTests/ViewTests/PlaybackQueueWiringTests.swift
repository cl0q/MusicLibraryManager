import Testing
import Foundation

/// Source-scan tests verifying that play sites pass the queue through
/// to `playTrack(_:queue:)` so the playback queue advances past the
/// current track when it ends.
@Suite("PlaybackQueueWiringTests")
struct PlaybackQueueWiringTests {

    private static var repoRoot: URL {
        let url = URL(fileURLWithPath: #filePath)
        return url
            .deletingLastPathComponent() // ViewTests
            .deletingLastPathComponent() // MLMTests
            .deletingLastPathComponent() // repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - ContentView handleTrackDoubleClick

    @Test
    func contentView_handleTrackDoubleClick_passesQueue() throws {
        let src = try readSource("MLM/Views/ContentView/ContentView.swift")
        #expect(src.contains("playTrack(track, queue: queue)"),
                "handleTrackDoubleClick must call playTrack(track, queue: queue) to wire the visible track list into the playback queue")
    }

    // MARK: - TrackContextMenu playSelectedTrack

    @Test
    func trackContextMenu_playSelectedTrack_passesQueue() throws {
        let src = try readSource("MLM/Views/Library/TrackContextMenu.swift")
        #expect(src.contains("playTrack(track, queue: selectedTracks)"),
                "TrackContextMenu.playSelectedTrack must pass selectedTracks as the queue")
    }

    // MARK: - PlaylistTable

    @Test
    func playlistTable_passesDisplayedTracksAsQueue() throws {
        let src = try readSource("MLM/Views/Playlists/PlaylistTable.swift")
        // PlaylistTable forwards displayedTracks via onTrackDoubleClick
        #expect(src.contains("onTrackDoubleClick?(track, viewModel.displayedTracks)"),
                "PlaylistTable must pass viewModel.displayedTracks as the queue to onTrackDoubleClick")
    }
}
