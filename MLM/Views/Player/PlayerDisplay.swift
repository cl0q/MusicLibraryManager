import Foundation

/// What the toolbar player's title area says (UC-TB-06/07, §15.7) — pure, unit-tested.
/// Precedence: a running preview, then the loaded main track, then why nothing can play,
/// then `Not playing`.
struct PlayerDisplay: Equatable {
    enum Mode: Equatable {
        case idle
        case track
        /// The `Preview` tag (or `Preview · from ‹Source›`) before the title.
        case preview(tag: String)
        case cantPlay(PlaybackWords.CantPlay)
    }

    let mode: Mode
    let title: String
    /// Artist — Album, the preview hint, or the `Can’t play — …` sentence.
    let secondLine: String?
    /// The one fix next to a `Can’t play` sentence (`Download`, `Locate…`).
    let fixTitle: String?
    /// Elapsed / duration are hidden when idle (E08).
    let showsTimes: Bool
    /// The cover shown (main or previewed track).
    let coverTrackID: Int64?

    /// - Parameter currentCantPlay: why the loaded (paused) main track can't play now — its
    ///   disk went away; the sentence replaces its artist line.
    static func make(current: Track?, preview: Track?, previewSource: String? = nil, cantPlay: CantPlayState?,
                     currentCantPlay: PlaybackWords.CantPlay? = nil, previewIsResolving: Bool = false) -> PlayerDisplay {
        if let preview {
            // A stream preview says `Resolving…` while its link is looked up (IMP-109), then Esc.
            let second = preview.isPreviewStream
                ? (previewIsResolving ? PlaybackWords.resolvingWord : PlaybackWords.streamPreviewHint)
                : PlaybackWords.previewHint
            return PlayerDisplay(mode: .preview(tag: PlaybackWords.previewTag(fromSource: previewSource)),
                                 title: preview.title, secondLine: second, fixTitle: nil,
                                 showsTimes: !(preview.isPreviewStream && previewIsResolving), coverTrackID: preview.id)
        }
        if let current {
            return PlayerDisplay(mode: .track, title: current.title,
                                 secondLine: currentCantPlay?.playerSentence ?? artistAlbum(current), fixTitle: nil,
                                 showsTimes: true, coverTrackID: current.id)
        }
        if let cantPlay {
            return PlayerDisplay(mode: .cantPlay(cantPlay.reason), title: cantPlay.track.title,
                                 secondLine: cantPlay.reason.playerSentence, fixTitle: cantPlay.reason.fixTitle,
                                 showsTimes: false, coverTrackID: cantPlay.track.id)
        }
        return PlayerDisplay(mode: .idle, title: PlaybackWords.notPlaying, secondLine: nil, fixTitle: nil,
                             showsTimes: false, coverTrackID: nil)
    }

    /// `Artist — Album`; a placeholder or source name as album shows nothing (DEC-013, E05).
    static func artistAlbum(_ track: Track) -> String? {
        let parts = [TrackMetadataPresentation.artistDisplay(track.artist), TrackMetadataPresentation.albumDisplay(track.album)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}
