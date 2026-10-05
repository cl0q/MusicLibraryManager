import SwiftUI

// MARK: Accessibility labels for shotty UI automation (snake_case literals)

/// The library track table — thin wrapper around the shared `TrackTable`.
///
/// Sorting is SQL-driven: header clicks update `LibraryViewModel.sortDescriptor`,
/// which re-fetches `displayedTracks` from the database.
struct LibraryTable: View {
    @Bindable var viewModel: LibraryViewModel
    @Environment(\.container) private var container

    /// Callback when a track is double-clicked (primary action).
    /// Receives the clicked track and the visible rows in display order
    /// (the playback queue).
    var onDoubleClick: ((Track, [Track]) -> Void)?

    /// Playlists available for the "Add to Playlist" submenu — loaded by
    /// the parent (LibraryView) so the submenu doesn't have to do its own
    /// async fetch (which is unreliable inside `Menu` in `contextMenu`).
    var availablePlaylists: [Playlist] = []

    /// Sync profiles available for the sync-profile submenu — loaded by LibraryView.
    var availableSyncProfiles: [SyncProfile] = []

    /// Cached row wrappers — rebuilt only when displayedTracks changes,
    /// not on every body evaluation (avoids 12k struct allocations per render).
    @State private var cachedRows: [TrackTable.Row] = []

    var body: some View {
        TrackTable(
            rows: cachedRows,
            selection: $viewModel.selectedTrackIDs,
            onSortChange: { column, ascending in
                viewModel.sortDescriptor = TrackSortDescriptor(column: column, ascending: ascending)
            },
            onDoubleClick: onDoubleClick,
            availabilityByTrackID: viewModel.availabilityByTrackID,
            availablePlaylists: availablePlaylists,
            availableSyncProfiles: availableSyncProfiles,
            addToSyncProfile: { profile, ids in
                Task {
                    container.syncViewModel?.selectedProfile = profile
                    await container.syncViewModel?.addTracks(Array(ids))
                }
            },
            isLoading: viewModel.isLoading,
            errorMessage: viewModel.errorMessage,
            listContext: .allTracks,
            emptyContent: {
                if viewModel.searchQuery.isEmpty {
                    ContentUnavailableView {
                        Label(
                            viewModel.selectedTab == .local ? "No local tracks" : "No remote tracks",
                            systemImage: "music.note"
                        )
                    } description: {
                        if viewModel.selectedTab == .local {
                            Text("Import music or download from Remote to get started.")
                        }
                    }
                } else {
                    ContentUnavailableView.search(text: viewModel.searchQuery)
                }
            },
            accessibilityID: "library_table"
        )
        .task {
            rebuildRowsIfNeeded()
        }
        .onChange(of: viewModel.displayedTracks) {
            rebuildRowsIfNeeded()
        }
    }

    /// Rebuild cached row wrappers only when the track array actually changed.
    private func rebuildRowsIfNeeded() {
        let tracks = viewModel.displayedTracks
        cachedRows = tracks.compactMap { track in
            track.id.map { TrackTable.Row(id: $0, track: track) }
        }
    }
}
