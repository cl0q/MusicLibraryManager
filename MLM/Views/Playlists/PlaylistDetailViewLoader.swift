import SwiftUI

/// Sidebar-to-detail routing shim (Plan 36-04, D-09).
///
/// `SidebarSection.playlistDetail(Int64)` flows through `ContentView`'s
/// routing switch into this view, which lazily fetches the `Playlist` by id
/// and renders `PlaylistDetailView`. Bypasses the grid intermediary so
/// clicking a pinned-sidebar playlist lands directly on its detail view
/// (Apple-Music sidebar behaviour).
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
    let onBack: () -> Void
    let onTrackDoubleClick: ((Track, [Track]) -> Void)?

    @Environment(\.container) private var container
    @State private var playlist: Playlist?
    @State private var loadFailed = false

    var body: some View {
        // [navperf] temporary instrumentation — remove after measurement
        let _ = print("[navperf] section-body playlistDetailLoader \(Date().timeIntervalSince1970)")
        Group {
            if let pl = playlist {
                PlaylistDetailView(
                    playlist: pl,
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
            // [navperf] temporary instrumentation — remove after measurement
            print("[navperf] section-task-start playlistDetailLoader \(Date().timeIntervalSince1970)")
            loadFailed = false
            playlist = nil
            guard let repo = container.playlistRepository else {
                loadFailed = true
                return
            }
            do {
                let fetched = try await repo.fetch(id: playlistId)
                // [navperf] temporary instrumentation — remove after measurement
                print("[navperf] section-task-after-first-await playlistDetailLoader \(Date().timeIntervalSince1970)")
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
