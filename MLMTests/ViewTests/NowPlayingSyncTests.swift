import Testing
import Foundation

/// Source-scan tests verifying that:
/// 1. Info never follows the now-playing track (UC-TRAIL-03 / DEC-007, W1-1 replaced the old
///    "detail pane follows the playing track" behaviour).
/// 2. All three track tables (TrackTable, PlaylistTable, FoldersView) apply the accent highlight.
/// 3. Existing invariants (speaker icon) remain intact; Info follows the selection (W2-E).
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
    /// W2-A: every track list (All Tracks, playlist, search, queue) draws its rows with the
    /// shared `TrackCell`, so the now-playing rules are checked there once (UC-TABLE-16).
    private static let trackTablePath = "MLM/Views/TrackList/TrackCell.swift"
    private static let playlistTablePath = "MLM/Views/TrackList/TrackCell.swift"
    /// W3-FOLD: the Folders outline draws its track rows with the shared `TrackCell` too.
    private static let foldersViewPath = "MLM/Views/Folders/FolderOutlineTable.swift"

    // MARK: - Task B (revised): Info never follows the playing track

    @Test
    func contentView_infoDoesNotFollowNowPlaying() throws {
        let src = try readSource(Self.contentViewPath)
        #expect(!src.contains(".onChange(of: container.playbackViewModel?.currentTrack)"),
                "Info follows the selection, never the playing track (UC-TRAIL-03)")
        #expect(!src.contains("selectedTrackForDetail = newTrack"))
    }

    @Test
    func contentView_trackActivationNeverOpensTheColumn() throws {
        let src = try readSource(Self.contentViewPath)
        let start = try #require(src.range(of: "private func handleTrackDoubleClick"))
        let body = String(src[start.lowerBound...].prefix(600))
        #expect(!body.contains("isPresented = true") && !body.contains("toggle("),
                "Double-click / Return must not open the trailing column (UC-TRAIL-02)")
    }

    // MARK: - Task A: accent highlight in all three tables

    @Test
    func trackTable_appliesAccentForegroundStyle() throws {
        let src = try readSource(Self.trackTablePath)
        #expect(src.contains(".foregroundStyle(.tint)"),
                "The now-playing glyph uses the accent (.tint, UC-TABLE-16)")
        #expect(src.contains("if presentation.isNowPlaying { return AnyShapeStyle(.tint) }"),
                "The now-playing title is drawn in the accent")
    }

    @Test
    func playlistTable_appliesAccentForegroundStyle() throws {
        let src = try readSource(Self.playlistTablePath)
        #expect(src.contains(".symbolEffect(.variableColor.iterative, isActive: live.isPlaying && !reduceMotion)"),
                "The glyph animates while playing and is static while paused (UC-TABLE-16)")
        #expect(try readSource("MLM/Views/Playlists/PlaylistTable.swift").contains("TrackListTable("),
                "The playlist table is the shared table")
    }

    @Test
    func foldersView_appliesAccentForegroundStyle() throws {
        let src = try readSource(Self.foldersViewPath)
        #expect(src.contains("TrackCell(column: column, row: track)"),
                "Folders track rows are drawn by the shared TrackCell (accent title and glyph, UC-TABLE-16)")
        #expect(!src.contains("mlm"), "no mlm* tokens in the rebuilt Folders table")
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
        // The glyph lives in the shared cell the Folders rows use.
        #expect(try readSource(Self.trackTablePath).contains("speaker.wave.2.fill"))
        #expect(try readSource(Self.foldersViewPath).contains("TrackCell("))
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
        #expect(try readSource(Self.trackTablePath).contains("isNowPlaying"),
                "the shared cell the Folders rows use decides now playing")
    }

    /// W2-E: Info follows the selection (`InspectedTrackSelection`); playing a track never
    /// changes what Info shows (UC-TRAIL-03).
    @Test
    func infoFollowsTheSelectionNotTheActivatedTrack() throws {
        let src = try readSource(Self.contentViewPath)
        #expect(!src.contains("selectedTrackForDetail"))
        let column = try readSource("MLM/Views/Shell/TrailingColumnView.swift")
        #expect(column.contains("InspectorView(selection: request.effectiveSelection(inspected.trackIDs))"))
        #expect(!src.contains("InspectedTrackSelection.shared.update"), "the table selection is never written here")
    }
}
