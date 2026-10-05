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
        // W2-A: menu Play with several rows plays the playable selected tracks as the queue.
        let src = try readSource("MLM/Views/TrackList/TrackListActions.swift")
        #expect(src.contains("configuration.activate?(first.track, playable.map(\\.track))"),
                "Play on a multi-selection must pass the selected playable tracks as the queue")
    }

    // MARK: - Shared track table (playlist, All Tracks, search)

    @Test
    func playlistTable_passesDisplayedTracksAsQueue() throws {
        // W2-A: every track table's primary action plays with its rows in display order.
        let src = try readSource("MLM/Views/TrackList/TrackListActions.swift")
        #expect(src.contains("configuration.activate?(row.track, model.tracks)"),
                "The primary action must pass the displayed rows as the queue")
        #expect(try readSource("MLM/Views/Playlists/PlaylistTable.swift").contains("activate: onTrackDoubleClick"))
    }
}
