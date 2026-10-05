import Foundation

/// Track ▸ Go to Artist and the context menu's item (UC-MENU-05, CM-TRACK, W2-I): All Tracks
/// filtered in place by the token `artist: ‹name›` (exact; artist or album artist), scope
/// `This view`. One track with a real artist (`Unknown Artist` is no artist).
@MainActor
enum GoToArtist {
    static let disabledReason = "Select one track with an artist."

    /// The artist of a one-track selection; `nil` otherwise.
    static func artist(of selection: TrackSelection?) -> String? {
        guard let selection, selection.summary.count == 1, let track = selection.selectedTracks.first else { return nil }
        return TrackMetadataPresentation.artistDisplay(track.artist)
    }
}
