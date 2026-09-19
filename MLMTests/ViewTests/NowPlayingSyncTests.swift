import Testing
import Foundation

/// Source-scan tests verifying that:
/// 1. The detail pane follows the now-playing track (onChange on currentTrack with pane-open guard).
/// 2. All three track tables (TrackTable, PlaylistTable, FoldersView) apply the accent highlight.
/// 3. Existing invariants (speaker icon, double-click detail wiring) remain intact.
@Suite("NowPlayingSyncTests")
struct NowPlayingSyncTests {

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

    private static let contentViewPath = "MLM/Views/ContentView/ContentView.swift"
    private static let trackTablePath = "MLM/Views/Library/TrackTable.swift"
    private static let playlistTablePath = "MLM/Views/Playlists/PlaylistTable.swift"
    private static let foldersViewPath = "MLM/Views/Folders/FoldersView.swift"

    // MARK: - Task B: detail pane follows the playing track

    @Test
    func contentView_containsOnChangeOfCurrentTrack() throws {
        let src = try readSource(Self.contentViewPath)
        #expect(src.contains(".onChange(of: container.playbackViewModel?.currentTrack)"),
                "ContentView must observe playbackViewModel.currentTrack changes")
    }

    @Test
    func contentView_detailSyncGuardsOnPaneOpen() throws {
        let src = try readSource(Self.contentViewPath)
        #expect(src.contains("selectedTrackForDetail != nil"),
                "Detail sync onChange must guard on selectedTrackForDetail != nil (pane-open guard)")
    }

    @Test
    func contentView_detailSyncDoesNotClearOnNil() throws {
        // The onChange body must NOT assign nil to selectedTrackForDetail.
        // The guard `newTrack != nil` ensures the nil path (stop/queue exhausted) is a no-op.
        let src = try readSource(Self.contentViewPath)
        #expect(src.contains("newTrack != nil"),
                "Detail sync onChange must guard on newTrack != nil so stop/nil does not clear detail")
    }

    @Test
    func contentView_detailSyncAssignsNewTrack() throws {
        let src = try readSource(Self.contentViewPath)
        #expect(src.contains("selectedTrackForDetail = newTrack"),
                "Detail sync onChange must assign the new track to selectedTrackForDetail")
    }

    // MARK: - Task A: accent highlight in all three tables

    @Test
    func trackTable_appliesAccentForegroundStyle() throws {
        let src = try readSource(Self.trackTablePath)
        #expect(src.contains("Color.mlmAccent"),
                "TrackTable must use Color.mlmAccent for now-playing highlight")
        #expect(src.contains("foregroundStyle(isNowPlaying(track)"),
                "TrackTable title must apply conditional foregroundStyle based on isNowPlaying")
    }

    @Test
    func playlistTable_appliesAccentForegroundStyle() throws {
        let src = try readSource(Self.playlistTablePath)
        #expect(src.contains("Color.mlmAccent"),
                "PlaylistTable must use Color.mlmAccent for now-playing highlight")
        #expect(src.contains("foregroundStyle(isPlaying"),
                "PlaylistTable title cell must apply conditional foregroundStyle based on isPlaying")
    }

    @Test
    func foldersView_appliesAccentForegroundStyle() throws {
        let src = try readSource(Self.foldersViewPath)
        #expect(src.contains("Color.mlmAccent"),
                "FoldersView must use Color.mlmAccent for now-playing highlight")
        #expect(src.contains("foregroundStyle(isNowPlaying(row.track)"),
                "FoldersView title must apply conditional foregroundStyle based on isNowPlaying")
    }

    // MARK: - Existing invariants preserved

    @Test
    func trackTable_stillContainsSpeakerIcon() throws {
        let src = try readSource(Self.trackTablePath)
        #expect(src.contains("speaker.wave.2.fill"),
                "TrackTable must still contain the speaker.wave.2.fill icon")
    }

    @Test
    func playlistTable_stillContainsSpeakerIcon() throws {
        let src = try readSource(Self.playlistTablePath)
        #expect(src.contains("speaker.wave.2.fill"),
                "PlaylistTable must still contain the speaker.wave.2.fill icon")
    }

    @Test
    func foldersView_stillContainsSpeakerIcon() throws {
        let src = try readSource(Self.foldersViewPath)
        #expect(src.contains("speaker.wave.2.fill"),
                "FoldersView must still contain the speaker.wave.2.fill icon")
    }

    @Test
    func trackTable_stillContainsIsNowPlaying() throws {
        let src = try readSource(Self.trackTablePath)
        #expect(src.contains("isNowPlaying"),
                "TrackTable must still contain the isNowPlaying helper")
    }

    @Test
    func playlistTable_stillContainsIsNowPlaying() throws {
        let src = try readSource(Self.playlistTablePath)
        #expect(src.contains("isNowPlaying"),
                "PlaylistTable must still contain the isNowPlaying helper")
    }

    @Test
    func foldersView_stillContainsIsNowPlaying() throws {
        let src = try readSource(Self.foldersViewPath)
        #expect(src.contains("isNowPlaying"),
                "FoldersView must still contain the isNowPlaying helper")
    }

    @Test
    func contentView_stillContainsDoubleClickDetailAssignment() throws {
        let src = try readSource(Self.contentViewPath)
        #expect(src.contains("selectedTrackForDetail = track"),
                "ContentView handleTrackDoubleClick must still assign selectedTrackForDetail = track")
    }
}
