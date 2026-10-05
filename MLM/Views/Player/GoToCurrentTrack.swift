import Observation
import SwiftUI

// MARK: - Go to Current Track ⌘L (UC-KEY-11, M-VIEW.N07, P-PLAYER.E05)

/// A request for a track table to select (and scroll to) a row once it shows it. The table of
/// the matching list (`TrackListConfiguration.persistenceKey` + container) takes it.
@MainActor
@Observable
final class TrackListReveal {
    static let shared = TrackListReveal()

    struct Request: Equatable {
        let id = UUID()
        let trackID: Int64
        let listKey: String
        let container: TrackListContainer

        func matches(listKey: String, container: TrackListContainer) -> Bool {
            self.listKey == listKey && self.container == container
        }
    }

    private(set) var request: Request?

    func reveal(trackID: Int64, listKey: String, container: TrackListContainer) {
        request = Request(trackID: trackID, listKey: listKey, container: container)
    }

    func done(_ id: UUID) {
        if request?.id == id { request = nil }
    }
}

extension PlaybackOrigin {
    /// Where a track plays from when no list recorded it (shuffle from the menu, the Dock):
    /// All Tracks lists every track.
    static let allTracks = PlaybackOrigin(place: .allTracks, path: [], listKey: "allTracks", container: .library)
}

@MainActor
enum GoToCurrentTrack {
    /// Show the playing track in the list it plays from and select it there (the view's
    /// search is cleared so the row can show). Never plays or opens anything else.
    static func perform(playback: PlaybackViewModel?, navigation: NavigationModel?, search: ToolbarSearchModel?) {
        guard let navigation, let track = playback?.currentTrack, let id = track.id else { return }
        let origin = playback?.playingOrigin ?? .allTracks
        if navigation.selection != origin.place {
            navigation.select(origin.place)
        }
        if navigation.path != origin.path {
            navigation.setPath(origin.path)
        }
        if let search, !search.text.isEmpty || search.isPresented {
            search.reset()
        }
        // All Tracks keeps a scope that lists the track, else switches to All (W2-B, IMP-028).
        if origin.place == .allTracks, origin.path.isEmpty {
            DependencyContainer.shared.libraryViewModel?.reveal(trackID: id, availability: track.availability())
        }
        TrackListReveal.shared.reveal(trackID: id, listKey: origin.listKey, container: origin.container)
    }
}
