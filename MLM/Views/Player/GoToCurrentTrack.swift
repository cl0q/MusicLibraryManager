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
        /// For the sentence when the list no longer has the track.
        let title: String
        let listKey: String
        let container: TrackListContainer

        func matches(listKey: String, container: TrackListContainer) -> Bool {
            self.listKey == listKey && self.container == container
        }
    }

    private(set) var request: Request?

    func reveal(trackID: Int64, title: String = "", listKey: String, container: TrackListContainer) {
        request = Request(trackID: trackID, title: title, listKey: listKey, container: container)
    }

    /// How long a loaded list may lack the track before the request ends with a sentence (the
    /// list may still be switching its scope or reloading).
    static let absentGrace: Duration = .milliseconds(1500)

    /// `“‹title›” isn’t in this list any more` (UC-SHEET-19 shape).
    static func absentMessage(title: String) -> String {
        "“\(title)” isn’t in this list any more"
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
        let origin = validated(playback?.playingOrigin)
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
        TrackListReveal.shared.reveal(trackID: id, title: track.title, listKey: origin.listKey, container: origin.container)
    }

    /// The recorded place, if it still exists — a deleted playlist or sync profile falls back to
    /// All Tracks (W2-C review S6).
    static func validated(_ origin: PlaybackOrigin?, sources: TrackMenuSources? = nil) -> PlaybackOrigin {
        guard let origin else { return .allTracks }
        let sources = sources ?? .shared
        let playlistIDs = Set(sources.playlists.compactMap(\.id))
        let profileIDs = Set(sources.syncProfiles.compactMap(\.id))
        func exists(_ destination: SidebarDestination) -> Bool {
            switch destination {
            case .playlist(let id): playlistIDs.contains(id)
            case .syncProfile(let id): profileIDs.contains(id)
            default: true
            }
        }
        guard exists(origin.place) else { return .allTracks }
        for route in origin.path {
            if case .playlist(let id, _) = route, !playlistIDs.contains(id) { return .allTracks }
        }
        switch origin.container {
        case .playlist(let id, _) where !playlistIDs.contains(id): return .allTracks
        case .syncProfile(let id, _) where !profileIDs.contains(id): return .allTracks
        default: return origin
        }
    }
}
