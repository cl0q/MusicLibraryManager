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
        ContentScaffold(showsDriveBanner: destination.listsTracks) {
            content
        } selectionBar: {
            // Shown only over a track table that registers (playlist detail; W2-G).
            TrackSelectionBar()
        }
        .hostsTrackSelectionBar()
        .modifier(WindowTitleModifier())
    }

    @ViewBuilder
    private var content: some View {
        switch destination {
        case .allTracks:
            // Hosted by ContentView (kept alive); nothing to draw here.
            Color.clear
        case .albums:
            PendingDestinationView(
                title: "Albums",
                systemImage: SidebarDestination.albums.systemImage,
                description: "Albums aren’t available yet."
            )
        case .genres:
            PendingDestinationView(
                title: "Genres",
                systemImage: SidebarDestination.genres.systemImage,
                description: "Genres aren’t available yet."
            )
        case .folders:
            FoldersView(onTrackDoubleClick: onTrackActivated)
        case .discover:
            DiscoverView()
        case .review:
            ReviewQueueView(focusTrackID: reviewFocusTrackID)
        case .allPlaylists:
            PlaylistsView(onTrackDoubleClick: onTrackActivated)
                .statusBarText(StatusBarText.playlists(sidebar.playlists.count))
        case .playlist(let id):
            PlaylistDetailViewLoader(
                playlistId: id,
                onBack: { navigation.select(.allPlaylists) },
                onTrackDoubleClick: onTrackActivated
            )
            .id(id)
        case .syncProfile(let id):
            SyncProfileHost(profileID: id)
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
        ContentScaffold(showsDriveBanner: route.listsTracks) {
            content
        } selectionBar: {
            TrackSelectionBar()
        }
        .hostsTrackSelectionBar()
        .modifier(WindowTitleModifier())
        .navigationBarBackButtonHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .playlist(let id, let showFailedTracks):
            PlaylistDetailViewLoader(
                playlistId: id,
                initiallyShowFailedTracks: showFailedTracks,
                onBack: { navigation.goBack() },
                onTrackDoubleClick: onTrackActivated
            )
            .id(id)
        case .album:
            PendingDestinationView(
                title: "Album",
                systemImage: "square.stack",
                description: "Album pages aren’t available yet."
            )
        case .genre(let name):
            PendingDestinationView(
                title: name,
                systemImage: "guitars",
                description: "Genre pages aren’t available yet."
            )
        case .similar:
            PendingDestinationView(
                title: "Similar",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: "Similar tracks aren’t available yet."
            )
        }
    }
}

// MARK: - Helpers

/// A destination whose redesigned view is not built yet (Albums, Genres, reserved routes).
struct PendingDestinationView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        }
    }
}

/// A sync profile as a sidebar destination: the existing profile detail. `SyncViewModel`
/// acts on its `selectedProfile` (preview, Sync Now, settings edits), so page and selection
/// are kept in agreement (`SyncProfilePageAgreement`), and the detail is only shown while
/// they agree — it can never show profile A while its buttons act on profile B.
private struct SyncProfileHost: View {
    let profileID: Int64

    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        if let vm = container.syncViewModel,
           let profile = vm.profiles.first(where: { $0.id == profileID }) {
            Group {
                if vm.selectedProfile?.id == profileID {
                    SyncProfileDetailView(profile: profile)
                } else {
                    Color.clear
                }
            }
            .task(id: profileID) {
                reconcile(vm, selected: vm.selectedProfile?.id, page: profile)
            }
            .onChange(of: vm.selectedProfile?.id) { _, selected in
                reconcile(vm, selected: selected, page: profile)
            }
        } else {
            ContentUnavailableView(
                "Sync profile not found",
                systemImage: "externaldrive",
                description: Text("It may have been deleted.")
            )
        }
    }

    private func reconcile(_ vm: SyncViewModel, selected: Int64?, page: SyncProfile) {
        switch SyncProfilePageAgreement.reconcile(
            pageProfileID: profileID,
            selectedProfileID: selected,
            profileIDs: vm.profiles.compactMap(\.id)
        ) {
        case .agree:
            break
        case .followSelection(let id):
            navigation.select(.syncProfile(id))
        case .selectPage:
            Task { await vm.selectProfile(page) }
        }
    }
}

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
            syncProfile: { id in container.syncViewModel?.profiles.first { $0.id == id }?.name }
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
