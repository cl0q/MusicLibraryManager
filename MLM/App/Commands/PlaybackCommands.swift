import AppKit
import SwiftUI

/// Playback menu (M-PLAYBACK, DEC-047; fixes PP-SHELL-03). Play / Pause has no key — the media
/// keys, the toolbar button, this item and the Dock menu play and pause (§10 Q1, UC-KEY-37).
/// The arrow keys with ⌘ / ⌥⌘ are ordinary menu keys of the main window; while a text field is
/// editing they keep their text meaning (`KeyEquivalentGuard`, UC-KEY-38). Plain ←/→ are not
/// bound anywhere (preview seeking is W2-C).
struct PlaybackCommands: Commands {
    @FocusedValue(\.playbackViewModel) private var playback
    @FocusedValue(\.trackSelection) private var focusedSelection
    @FocusedValue(\.navigationModel) private var navigation

    var body: some Commands {
        CommandMenu(MenuBarMenu.playback.rawValue) {
            let hasTrack = playback?.hasTrack == true
            let list = PlayableList.current(
                selection: TrackSelection.usable(focusedSelection, navigation: navigation),
                navigation: navigation,
                playback: playback
            )

            // With nothing loaded, Play plays the current view (UC-MENU-05).
            CommandButton(.playPause,
                          title: playback?.isPlaying == true ? "Pause" : "Play",
                          enabled: hasTrack || list?.canPlay == true) {
                if let playback, playback.hasTrack {
                    playback.togglePlayPause()
                } else {
                    list?.play()
                }
            }
            CommandButton(.stop, enabled: hasTrack) {
                guard !KeyEquivalentGuard.keyCancelsSheet() else { return }
                playback?.stop()
            }

            Divider()

            CommandButton(.next, enabled: hasTrack) {
                guard !KeyEquivalentGuard.keyBelongsToText(.textCommand(#selector(NSResponder.moveToEndOfLine(_:)))) else { return }
                Task { await playback?.next() }
            }
            CommandButton(.previous, enabled: hasTrack) {
                guard !KeyEquivalentGuard.keyBelongsToText(.textCommand(#selector(NSResponder.moveToBeginningOfLine(_:)))) else { return }
                Task { await playback?.back() }
            }
            CommandButton(.skipForward, enabled: hasTrack) {
                guard !KeyEquivalentGuard.keyBelongsToText(.nothing) else { return }
                playback?.seekBy(PlaybackStep.skipSeconds)
            }
            CommandButton(.skipBack, enabled: hasTrack) {
                guard !KeyEquivalentGuard.keyBelongsToText(.nothing) else { return }
                playback?.seekBy(-PlaybackStep.skipSeconds)
            }

            Divider()

            // Works on the current volume; persisting it is W2-C.
            CommandButton(.volumeUp, enabled: (playback?.volume ?? 1) < 1) {
                guard !KeyEquivalentGuard.keyBelongsToText(.textCommand(#selector(NSResponder.moveToBeginningOfDocument(_:)))) else { return }
                if let playback { playback.setVolume(PlaybackStep.volume(after: playback.volume, up: true)) }
            }
            CommandButton(.volumeDown, enabled: (playback?.volume ?? 0) > 0) {
                guard !KeyEquivalentGuard.keyBelongsToText(.textCommand(#selector(NSResponder.moveToEndOfDocument(_:)))) else { return }
                if let playback { playback.setVolume(PlaybackStep.volume(after: playback.volume, up: false)) }
            }

            Divider()

            CommandButton(.shuffleView,
                          title: list.map { "Shuffle \($0.name)" } ?? MenuCommand.shuffleView.title,
                          enabled: list?.canPlay == true) {
                list?.shuffle()
            }
            CommandSubmenu(.repeatMode)

            Divider()

            CommandButton(.playView,
                          title: list.map { "Play \($0.name)" } ?? MenuCommand.playView.title,
                          enabled: list?.canPlay == true) {
                list?.play()
            }
        }
    }
}

// MARK: - Steps

/// Seek and volume steps of the Playback menu (UC-KEY-08/09).
enum PlaybackStep {
    /// Skip Forward / Back 10 Seconds.
    static let skipSeconds: TimeInterval = 10
    /// Volume Up / Down change the level by a tenth.
    static let volumeStepsPerUnit = 10.0

    /// The next volume level, on the tenths grid and clamped to 0…1.
    static func volume(after current: Double, up: Bool) -> Double {
        let tenths = (current * volumeStepsPerUnit).rounded()
        let next = up ? tenths + 1 : tenths - 1
        return min(max(next / volumeStepsPerUnit, 0), 1)
    }
}

// MARK: - The current view as a playable list

/// The list Playback ▸ Play ‹view› / Shuffle ‹view› act on: the focused track list when it is
/// named, else All Tracks while it is the visible place.
@MainActor
struct PlayableList {
    let name: String
    /// Rows in display order.
    let rows: [Track]
    /// The selection in display order (Play starts there when there is one).
    let selected: [Track]
    let activate: (Track, [Track]) -> Void

    var canPlay: Bool { rows.contains(where: \.isLocal) }

    /// Play from the first selected playable track, else from the first playable row; the rows
    /// after it are the queue context.
    func play() {
        guard let first = selected.first(where: \.isLocal) ?? rows.first(where: \.isLocal) else { return }
        activate(first, rows)
    }

    func shuffle() {
        let playable = rows.filter(\.isLocal)
        guard !playable.isEmpty, let playback = DependencyContainer.shared.playbackViewModel else { return }
        Task { await playback.playShuffled(playable) }
    }

    static func current(selection: TrackSelection?, navigation: NavigationModel?, playback: PlaybackViewModel?) -> PlayableList? {
        if let selection, let name = selection.context.viewName, let activate = selection.target.activate {
            return PlayableList(name: name, rows: selection.rows, selected: selection.selectedTracks, activate: activate)
        }
        guard let navigation, navigation.isAllTracksVisible,
              !DependencyContainer.shared.searchCoordinator.isPresented,
              let library = DependencyContainer.shared.libraryViewModel,
              let playback else { return nil }
        let rows = library.displayedTracks
        let selected = rows.filter { track in track.id.map(library.selectedTrackIDs.contains) ?? false }
        return PlayableList(name: TrackListContext.allTracks.viewName ?? "All Tracks", rows: rows, selected: selected) { track, queue in
            Task { await playback.playTrack(track, queue: queue) }
        }
    }
}
