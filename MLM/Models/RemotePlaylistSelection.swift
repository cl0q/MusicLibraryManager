import Foundation

/// How many tracks of a remote playlist to download.
enum RemotePlaylistSelection: Equatable {
    /// The entire playlist, in order.
    case all
    /// The first N tracks, in order.
    case firstN(Int)
    /// N randomly chosen tracks.
    case randomN(Int)

    /// Apply the selection to an ordered track list.
    func apply(to tracks: [Track]) -> [Track] {
        switch self {
        case .all:
            return tracks
        case .firstN(let n):
            return Array(tracks.prefix(max(0, n)))
        case .randomN(let n):
            return Array(tracks.shuffled().prefix(max(0, n)))
        }
    }
}
