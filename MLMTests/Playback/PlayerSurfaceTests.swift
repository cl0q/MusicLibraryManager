import Foundation
import Testing
@testable import MLM

/// W2-C: the toolbar player's words (UC-TB-06/07, §15.7), the table's preview keys
/// (UC-KEY-01/04/05, §10 Q1, DEC-047), menu wiring and the player's construction rules.
@Suite("PlayerSurfaceTests")
struct PlayerSurfaceTests {

    private func track(_ id: Int64, artist: String = "Mosca", album: String = "Bax") -> Track {
        var t = Track(artist: artist, album: album, title: "Glass Circuit", format: "m4a", originalPath: "soundcloud://\(id)")
        t.id = id
        t.organizedPath = "A/\(id).m4a"
        return t
    }

    // MARK: Player states in words

    @Test func playerStatesAreTheDesignedWords() {
        let idle = PlayerDisplay.make(current: nil, preview: nil, cantPlay: nil)
        #expect(idle.mode == .idle && idle.title == "Not playing" && idle.secondLine == nil && !idle.showsTimes)

        let playing = PlayerDisplay.make(current: track(1), preview: nil, cantPlay: nil)
        #expect(playing.mode == .track && playing.title == "Glass Circuit" && playing.secondLine == "Mosca — Bax" && playing.showsTimes)

        let preview = PlayerDisplay.make(current: track(1), preview: track(2), cantPlay: nil)
        #expect(preview.mode == .preview(tag: "Preview"))
        #expect(preview.secondLine == "Space to stop · Return to play")
        #expect(preview.coverTrackID == 2, "the cover follows the preview")
        #expect(PlayerDisplay.make(current: nil, preview: track(2), previewSource: "YouTube", cantPlay: nil).mode
                == .preview(tag: "Preview · from YouTube"))

        for (reason, sentence, fix) in [
            (PlaybackWords.CantPlay.notDownloaded, "Can’t play — not downloaded", "Download" as String?),
            (.fileMissing, "Can’t play — file missing", "Locate…"),
            (.driveNotConnected(volumeName: "Lexxar"), "Can’t play — “Lexxar” is not connected", nil),
        ] {
            let display = PlayerDisplay.make(current: nil, preview: nil, cantPlay: CantPlayState(track: track(3), reason: reason))
            #expect(display.title == "Glass Circuit")
            #expect(display.secondLine == sentence)
            #expect(display.fixTitle == fix)
            #expect(!display.showsTimes)
        }
    }

    @Test func aPausedTrackOnADiskThatIsAwaySaysSo() {
        let display = PlayerDisplay.make(current: track(1), preview: nil, cantPlay: nil,
                                         currentCantPlay: .driveNotConnected(volumeName: "Lexxar"))
        #expect(display.title == "Glass Circuit")
        #expect(display.secondLine == "Can’t play — “Lexxar” is not connected")
        #expect(display.showsTimes, "it is paused at its position")
    }

    @Test func aSourceNameAsAlbumShowsNothing() {
        #expect(PlayerDisplay.artistAlbum(track(1, album: "youtube")) == "Mosca", "DEC-013")
        #expect(PlayerDisplay.artistAlbum(track(1, artist: "", album: "")) == nil)
    }

    // MARK: Keys of the focused table

    private func decide(_ key: TrackListPreviewKey.Key, repeat isRepeat: Bool = false, modifiers: Bool = false,
                        previewing: Bool = false, typed: TimeInterval? = nil) -> TrackListPreviewKey.Decision {
        TrackListPreviewKey.decide(key: key, isRepeat: isRepeat, hasCommandModifiers: modifiers,
                                   isPreviewing: previewing, secondsSinceTypeSelect: typed)
    }

    @Test func spaceTogglesThePreviewAndNothingElse() {
        #expect(decide(.space) == .togglePreview)
        #expect(decide(.space, previewing: true) == .togglePreview, "Space again ends it")
        #expect(decide(.space, repeat: true) == .swallow, "holding Space doesn't flicker")
        #expect(decide(.space, modifiers: true) == .passOn, "⌃Space / ⌘Space are the system's")
        #expect(decide(.space, typed: 0.3) == .passOn, "a space inside a type-select is typed")
        #expect(decide(.space, typed: 2) == .togglePreview)
    }

    @Test func escAndArrowsAreThePreviewsOnlyWhilePreviewing() {
        #expect(decide(.escape) == .passOn)
        #expect(decide(.escape, previewing: true) == .endPreview)
        #expect(decide(.leftArrow) == .passOn, "←/→ belong to the table outside a preview (DEC-047)")
        #expect(decide(.rightArrow) == .passOn)
        #expect(decide(.leftArrow, previewing: true) == .seek(by: -5))
        #expect(decide(.rightArrow, repeat: true, previewing: true) == .seek(by: 5), "hold repeats")
        #expect(decide(.rightArrow, modifiers: true, previewing: true) == .passOn, "⌘→ is Next, ⌥⌘→ Skip Forward")
    }

    // MARK: Menus and construction (source checks where behaviour needs a window)

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func w2cMenuItemsAreWiredWithoutPlainKeys() {
        for command in [MenuCommand.preview, .locateFile, .repeatMode] {
            #expect(command.wiring == .app, "\(command)")
        }
        #expect(MenuCommand.preview.shortcut == nil, "Space is never a key equivalent (UC-KEY-37)")
        #expect(MenuCommand.playPause.shortcut == nil)
        #expect(MenuCommand.locateFile.title == "Locate File…")
        #expect(PlaybackRepeatMode.allCases.map(\.title) == ["Off", "All", "One"])
        #expect(TrackPreviewCommand.canPreview(TrackSelectionSummary(count: 1, localCount: 1, firstIsLocal: true)))
        #expect(!TrackPreviewCommand.canPreview(TrackSelectionSummary(count: 2, localCount: 2, firstIsLocal: true)))
        var missing = TrackSelectionSummary(count: 1)
        missing.missingCount = 1
        #expect(TrackPreviewCommand.canLocate(missing))
        #expect(!TrackPreviewCommand.canLocate(TrackSelectionSummary(count: 1, localCount: 1, firstIsLocal: true)))
    }

    @Test func thePlayerHasNoMaterialNoThemeTokensAndMorphsOnlyWithMotion() throws {
        for path in ["MLM/Views/Player/PlayerBar.swift", "MLM/Views/Player/PreviewWaveformScrubber.swift",
                     "MLM/Views/Player/PlayerDisplay.swift", "MLM/Views/Player/LocateFile.swift"] {
            let text = try source(path)
            #expect(!text.contains(".mlm") && !text.contains("MLMFont"), "\(path): no mlm* tokens (UC-COLOR-03)")
            #expect(!text.contains("Material") && !text.contains("glassEffect"), "\(path): no material in the player (UC-GLASS-01)")
            #expect(!text.contains("presentationBackground"), "\(path): system popover background (UC-GLASS-06)")
            #expect(!text.contains(".system(size:"), "\(path): system text styles only (UC-TYPE-01)")
            #expect(!text.contains("Color(red:"))
        }
        let bar = try source("MLM/Views/Player/PlayerBar.swift")
        #expect(bar.contains(".contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))"))
        #expect(bar.contains("accessibilityReduceMotion"))
        #expect(!bar.contains(".keyboardShortcut("), "the player defines no keys")
        #expect(!bar.contains("\"Not Playing\""), "sentence case (C22)")
    }

    /// Review S6: ⌘L returns to a recorded place only while it exists.
    @Test @MainActor func goToCurrentTrackFallsBackWhenThePlaceIsGone() {
        let noPlaylists = TrackMenuSources()
        let deleted = PlaybackOrigin(place: .playlist(42), path: [], listKey: "playlist",
                                     container: .playlist(id: 42, name: "Gone"))
        #expect(GoToCurrentTrack.validated(deleted, sources: noPlaylists) == .allTracks)
        let pushed = PlaybackOrigin(place: .allPlaylists, path: [.playlist(42, showFailedTracks: false)], listKey: "playlist",
                                    container: .playlist(id: 42, name: "Gone"))
        #expect(GoToCurrentTrack.validated(pushed, sources: noPlaylists) == .allTracks)
        #expect(GoToCurrentTrack.validated(.allTracks, sources: noPlaylists) == .allTracks)
        #expect(GoToCurrentTrack.validated(nil, sources: noPlaylists) == .allTracks)
        #expect(TrackListReveal.absentMessage(title: "Glass Circuit") == "“Glass Circuit” isn’t in this list any more")
    }
}
