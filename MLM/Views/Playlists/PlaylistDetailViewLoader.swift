import SwiftUI

/// Sidebar-to-detail routing shim (Plan 36-04, D-09).
///
/// `SidebarDestination.playlist(id)` (a sidebar row) and `DetailRoute.playlist(id)`
/// (pushed from the All Playlists grid) route through `DestinationView` / `RouteView`
/// into this view, which lazily fetches the `Playlist` by id and renders
/// `PlaylistDetailView`.
///
/// Why a loader rather than embedding `Playlist` directly in the enum:
/// the sidebar's pinned-list snapshot can lag behind a rename, delete, or
/// cover regeneration — always fetch fresh from the repo (cheap single-row
/// `Playlist.fetchOne(db, id:)`).
///
/// The `.task(id: playlistId)` reload-on-change makes the loader survive
/// sidebar re-clicks to *different* pinned playlists without unmounting.
struct PlaylistDetailViewLoader: View {
    let playlistId: Int64
    /// Open with the failed-download section expanded (the grid's "show failed" action).
    var initiallyShowFailedTracks = false
    let onBack: () -> Void
    let onTrackDoubleClick: ((Track, [Track]) -> Void)?

    @Environment(\.container) private var container
    @State private var playlist: Playlist?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let pl = playlist {
                PlaylistDetailView(
                    playlist: pl,
                    initiallyShowFailedTracks: initiallyShowFailedTracks,
                    onBack: onBack,
                    onTrackDoubleClick: onTrackDoubleClick
                )
            } else if loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.mlmInkMuted)
                    Text("Playlist not found")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkSecondary)
                    Button("Back to Playlists") { onBack() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.mlmBase)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mlmBase)
            }
        }
        .task(id: playlistId) {
            loadFailed = false
            playlist = nil
            guard let repo = container.playlistRepository else {
                loadFailed = true
                return
            }
            do {
                let fetched = try await repo.fetch(id: playlistId)
                if let fetched {
                    playlist = fetched
                } else {
                    loadFailed = true
                }
            } catch {
                loadFailed = true
            }
        }
    }

}
