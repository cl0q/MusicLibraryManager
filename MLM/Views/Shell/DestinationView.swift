import SwiftUI

/// Callback of the re-hosted track lists: a track was double-clicked / Return-ed, with the
/// visible rows as the queue context.
typealias TrackActivation = (Track, [Track]) -> Void

// MARK: - Sidebar destinations

/// The content of a sidebar destination, inside the content scaffold. All Tracks is not
/// routed here: `ContentView` keeps its very large table alive across switches (see
/// `LibraryHost`).
///
/// **Adding a destination:** add the case to `SidebarDestination`, then a `case` here that
/// returns its view (wrapped by the caller in `ContentScaffold`).
struct DestinationView: View {
    let destination: SidebarDestination
    let reviewFocusTrackID: Int64?
    let onTrackActivated: TrackActivation

    @Environment(NavigationModel.self) private var navigation
    @Environment(SidebarModel.self) private var sidebar

    var body: some View {
        switch destination {
        // The playlist pages build their own scaffold: the detail header and the grid's scope
        // bar are theirs (W3-PL, UC-LAYOUT-01/06).
        case .allPlaylists:
            PlaylistsView()
        case .playlist(let id):
            PlaylistDetailViewLoader(playlistId: id, onBack: { navigation.select(.allPlaylists) },
                                     onTrackDoubleClick: onTrackActivated)
                .id(id)
        // Folders builds its own scaffold: the path bar sits above the status bar and the
        // window title names the opened folder (W3-FOLD, V-FOLD.E01/E07).
        case .folders:
            FoldersView(onTrackActivated: onTrackActivated)
        // A sync profile page builds its own scaffold: the profile header and its banner
        // (W3-SYNC, UC-LAYOUT-01/02).
        case .syncProfile(let id):
            SyncProfilePage(profileID: id)
        // Albums builds its own scaffold: the scope bar with the sort control and the footer line
        // for the tracks that have no album (W4-2, V-ALB).
        case .albums:
            AlbumsView()
        case .genres:
            // Own scaffold: the list's command bar and footer line (W3-GEN).
            GenresView()
        // Review builds its own scaffold: its scope bar, banners and the scan line (W3-REV).
        case .review:
            ReviewView(focusTrackID: reviewFocusTrackID, onTrackActivated: onTrackActivated)
        // Discover builds its own scaffold: its scope bar, the held-recommendations header and the
        // selection bar over its tables (W3-DISC-A).
        case .discover:
            DiscoverView(onTrackActivated: onTrackActivated)
        default:
            ContentScaffold(showsDriveBanner: destination.listsTracks) {
                content
            } selectionBar: {
                // Shown only over a track table that registers (W2-G).
                TrackSelectionBar()
            }
            .hostsTrackSelectionBar()
            .modifier(WindowTitleModifier())
        }
    }

    @ViewBuilder
    private var content: some View {
        switch destination {
        case .allTracks:
            // Hosted by ContentView (kept alive); nothing to draw here.
            Color.clear
        case .albums:
            // Hosted by `body` (own scaffold).
            Color.clear
        case .genres:
            // Hosted by `body` (own scaffold).
            Color.clear
        case .folders:
            // Hosted by `body` (own scaffold).
            Color.clear
        case .discover:
            // Hosted by `body` (own scaffold).
            Color.clear
        case .review:
            // Hosted by `body` (own scaffold).
            Color.clear
        case .allPlaylists, .playlist:
            // Hosted by `body` (own scaffold).
            Color.clear
        case .syncProfile:
            // Hosted by `body` (own scaffold).
            Color.clear
        }
    }
}

// MARK: - Pushed details

/// The content of a pushed detail. Its back button is the toolbar's Back (⌘[), so the
/// system back button of `NavigationStack` is hidden.
///
/// **Adding a pushed route:** replace the route's placeholder below with the real view.
struct RouteView: View {
    let route: DetailRoute
    let onTrackActivated: TrackActivation

    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        Group {
            if case .playlist(let id, let showFailedTracks) = route {
                // Own scaffold: the playlist's detail header (W3-PL, UC-LAYOUT-06).
                PlaylistDetailViewLoader(playlistId: id, initiallyShowFailedTracks: showFailedTracks,
                                         onBack: { navigation.goBack() }, onTrackDoubleClick: onTrackActivated)
                    .id(id)
            } else if case .similar(let trackID) = route {
                // Own scaffold: the seed header, the library matches and the online suggestions (W3-DISC-A).
                SimilarView(trackID: trackID, onTrackActivated: onTrackActivated)
                    .id(trackID)
            } else if case .album(let id) = route {
                // Own scaffold: the album's header, status line and track list (W4-2, UC-LAYOUT-06).
                AlbumDetailView(albumID: id, onTrackActivated: onTrackActivated)
                    .id(id)
            } else if case .genre(let name) = route {
                // Own scaffold: the genre's detail header (W3-GEN, UC-LAYOUT-06).
                GenreDetailView(name: name, onTrackActivated: onTrackActivated)
                    .id(GenreName.key(name) ?? name)
            } else {
                ContentScaffold(showsDriveBanner: route.listsTracks) {
                    content
                } selectionBar: {
                    TrackSelectionBar()
                }
                .hostsTrackSelectionBar()
                .modifier(WindowTitleModifier())
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .playlist:
            // Hosted by `body` (own scaffold).
            Color.clear
        case .album:
            // Hosted by `body` (own scaffold).
            Color.clear
        case .genre:
            // Hosted by `body` (own scaffold).
            Color.clear
        case .similar:
            // Hosted by `body` (own scaffold).
            Color.clear
        }
    }
}

// MARK: - Helpers

/// Sets the window title (current place) and subtitle (library name + count where cheap),
/// UC-WIN-06. Applied to every scaffolded place so whichever is visible names the window.
struct WindowTitleModifier: ViewModifier {
    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation
    @Environment(SidebarModel.self) private var sidebar

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
    }

    private var title: String {
        navigation.title(names: PlaceNames(
            playlist: { sidebar.playlistName($0) },
            syncProfile: { id in container.syncViewModel?.profiles.first { $0.id == id }?.name },
            album: { AlbumNames.shared.name(for: $0) }
        ))
    }

    private var subtitle: String {
        let library = LibraryFooter.libraryName(LibraryLaunchCoordinator.shared)
        guard navigation.currentRoute == nil else { return library }
        switch navigation.selection {
        case .allTracks:
            guard let vm = container.libraryViewModel else { return library }
            return "\(library) · \(StatusBarText.tracks(vm.libraryTrackCount))"
        case .allPlaylists:
            return "\(library) · \(StatusBarText.playlists(sidebar.playlists.count))"
        default:
            return library
        }
    }
}
