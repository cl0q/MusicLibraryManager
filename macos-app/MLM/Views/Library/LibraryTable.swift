import SwiftUI

/// The library track table with sortable columns.
///
/// Native SwiftUI `Table` (macOS 13+). All columns are clickable headers
/// with system sort indicators via `KeyPathComparator`. Default sort is
/// `Added` descending (newest first).
struct LibraryTable: View {
    @Bindable var viewModel: LibraryViewModel
    @Environment(\.container) private var container

    /// Callback when a track is double-clicked (primary action).
    var onDoubleClick: ((Track) -> Void)?

    /// Playlists available for the "Add to Playlist" submenu — loaded by
    /// the parent (LibraryView) so the submenu doesn't have to do its own
    /// async fetch (which is unreliable inside `Menu`-in-`contextMenu`).
    var availablePlaylists: [Playlist] = []

    /// Sync profiles available for the "Sync zu" submenu — loaded by LibraryView.
    var availableSyncProfiles: [SyncProfile] = []

    /// Identifiable wrapper so `Table` selection can use `Set<Int64>`
    /// even though `Track.id` is `Int64?` for unsaved DB rows.
    private struct TrackRow: Identifiable {
        let id: Int64
        let track: Track
    }

    /// Sort order — default to `Added` descending so the newest tracks
    /// appear first, matching what most music apps do.
    @State private var sortOrder: [KeyPathComparator<TrackRow>] = [
        KeyPathComparator(\.track.dateAddedSortKey, order: .reverse)
    ]

    @State private var cachedRows: [TrackRow] = []

    var body: some View {
        Group {
            if viewModel.isLoading {
                loadingState
            } else if let error = viewModel.errorMessage {
                errorState(error)
            } else if viewModel.displayedTracks.isEmpty {
                emptyState
            } else {
                tableView
            }
        }
        .task {
            updateCachedRows()
        }
        .onChange(of: viewModel.displayedTracks) {
            updateCachedRows()
        }
    }

    // MARK: - Table

    private var tableView: some View {
        Table(selection: $viewModel.selectedTrackIDs, sortOrder: $sortOrder) {
            Group {
                TableColumn("Title", value: \TrackRow.track.title) { row in
                    let track = row.track
                    HStack(spacing: 8) {
                        // UI-SPEC Surface 1: 18pt thumbnail, cornerRadius 4, HStack spacing 8
                        TrackCoverView(trackId: track.id ?? 0, size: .small, cornerRadius: 4)
                            .frame(width: 18, height: 18)

                        if isNowPlaying(track) {
                            Image(systemName: "speaker.wave.2.fill")
                                .imageScale(.small)
                                .foregroundStyle(Color.accentColor)
                                .symbolEffect(.variableColor, isActive: true)
                        }
                        Text(track.title).lineLimit(1)
                    }
                }
                .width(min: 160, ideal: 280)

                TableColumn("Artist", value: \TrackRow.track.artist) { row in
                    Text(row.track.artist).lineLimit(1)
                }
                .width(min: 100, ideal: 180)

                TableColumn("Album", value: \TrackRow.track.album) { row in
                    Text(row.track.album).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 100, ideal: 180)

                TableColumn("Time", value: \TrackRow.track.durationSortKey) { row in
                    Text(row.track.formattedDuration)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(54)

                TableColumn("Format", value: \TrackRow.track.format) { row in
                    Text(row.track.isRemote ? "Stream" : row.track.format.uppercased())
                        .foregroundStyle(.secondary)
                }
                .width(60)
            }

            Group {
                TableColumn("kbps", value: \TrackRow.track.bitrateSortKey) { row in
                    Text(row.track.bitrate.map { "\($0)" } ?? "—")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(48)

                TableColumn("Genre", value: \TrackRow.track.genreSortKey) { row in
                    Text(row.track.genre ?? "—")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 70, ideal: 110)

                TableColumn("Year", value: \TrackRow.track.yearSortKey) { row in
                    Text(row.track.year.map { "\($0)" } ?? "—")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(48)

                TableColumn("Energy", value: \TrackRow.track.energySortKey) { row in
                    EnergyBars(level: row.track.energyBucket)
                }
                .width(56)

                TableColumn("Dance", value: \TrackRow.track.danceabilitySortKey) { row in
                    DanceabilitySteps(score: row.track.danceability)
                }
                .width(56)

                TableColumn("BPM", value: \TrackRow.track.bpmSortKey) { row in
                    Text(row.track.bpm.map { "\($0)" } ?? "—")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(48)

                TableColumn("Added", value: \TrackRow.track.dateAddedSortKey) { row in
                    Text(formatDateAdded(row.track.dateAddedLibrary ?? row.track.dateAdded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(78)
            }
        } rows: {
            ForEach(cachedRows) { row in
                TableRow(row)
                    .draggable(TrackDragData(trackId: row.id, sourcePlaylistId: nil))
            }
        }
        .contextMenu(forSelectionType: Int64.self) { selectedIDs in
            TrackContextMenu(
                selectedTrackIDs: selectedIDs,
                tracks: viewModel.displayedTracks,
                availablePlaylists: availablePlaylists,
                availableSyncProfiles: availableSyncProfiles,
                addToSyncProfile: { profile in
                    Task {
                        container.syncViewModel?.selectedProfile = profile
                        await container.syncViewModel?.addTracks(Array(selectedIDs))
                    }
                }
            )
        } primaryAction: { selectedIDs in
            if let trackID = selectedIDs.first,
               let track = viewModel.displayedTracks.first(where: { $0.id == trackID }) {
                onDoubleClick?(track)
            }
        }
        .onChange(of: sortOrder) { _, newOrder in
            guard let first = newOrder.first else { return }
            let col: SortColumn
            switch first.keyPath {
            case \TrackRow.track.title:          col = .title
            case \TrackRow.track.artist:         col = .artist
            case \TrackRow.track.album:          col = .album
            case \TrackRow.track.durationSortKey: col = .duration
            case \TrackRow.track.format:         col = .format
            case \TrackRow.track.bitrateSortKey: col = .bitrate
            case \TrackRow.track.genreSortKey:   col = .genre
            case \TrackRow.track.yearSortKey:    col = .year
            case \TrackRow.track.energySortKey:  col = .energy
            case \TrackRow.track.danceabilitySortKey: col = .danceability
            case \TrackRow.track.bpmSortKey:     col = .bpm
            case \TrackRow.track.dateAddedSortKey: col = .dateAdded
            default: return
            }
            let asc = first.order == .forward
            viewModel.sortDescriptor = TrackSortDescriptor(column: col, ascending: asc)
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading tracks…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Failed to load tracks", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
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
    }

    // MARK: - Helpers

    private func updateCachedRows() {
        self.cachedRows = viewModel.displayedTracks.compactMap { t in
            t.id.map { TrackRow(id: $0, track: t) }
        }
    }

    /// Whether a track is the currently playing track.
    private func isNowPlaying(_ track: Track) -> Bool {
        guard let playbackVM = container.playbackViewModel,
              let currentTrack = playbackVM.currentTrack,
              let currentID = currentTrack.id,
              let trackID = track.id else {
            return false
        }
        return currentID == trackID && playbackVM.isPlaying
    }

    /// Format date_added for display (e.g., "2026-05-07" → "May 7").
    private func formatDateAdded(_ dateString: String?) -> String {
        guard let dateString else { return "—" }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]

        if let date = formatter.date(from: String(dateString.prefix(10))) {
            let display = DateFormatter()
            display.dateFormat = "MMM d"
            return display.string(from: date)
        }

        return String(dateString.prefix(10))
    }
}
