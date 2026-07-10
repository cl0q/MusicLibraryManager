import SwiftUI
import UniformTypeIdentifiers

/// A premium, sortable, and reorderable track table for PlaylistDetailView.
///
/// Matches the visual layout, columns, badges, and animations of `LibraryTable`.
/// Adds support for native macOS blue horizontal line drag-and-drop reordering
/// and drops from other views using fractional positioning.
struct PlaylistTable: View {
    let playlist: Playlist
    @Bindable var viewModel: PlaylistDetailViewModel
    var availablePlaylists: [Playlist] = []
    var availableSyncProfiles: [SyncProfile] = []
    var onTrackDoubleClick: ((Track) -> Void)?
    var onRemoveTracks: (Set<Int64>) async -> Void

    @Environment(\.container) private var container

    /// Identifiable row wrapper with a 1-based natural index to represent
    /// position inside the playlist.
    struct TrackRow: Identifiable {
        let index: Int
        let id: Int64
        let track: Track
    }

    /// Sort order — default is by the natural playlist index (custom order)
    @State private var sortOrder: [KeyPathComparator<TrackRow>] = [
        KeyPathComparator(\.index, order: .forward)
    ]

    @State private var cachedRows: [TrackRow] = []

    /// Reordering/custom-positioning is only meaningful when in the default index order.
    private var isDefaultOrder: Bool {
        guard let first = sortOrder.first else { return true }
        return first.keyPath == \TrackRow.index && first.order == .forward
    }

    var body: some View {
        Group {
            Table(selection: $viewModel.selectedTrackIDs, sortOrder: $sortOrder) {
                Group {
                    TableColumn("#", value: \TrackRow.index) { row in
                        PlaylistTableIndexCell(index: row.index)
                    }
                    .width(28)

                    TableColumn("Title", value: \TrackRow.track.title) { row in
                        PlaylistTableTitleCell(track: row.track, isPlaying: isNowPlaying(row.track))
                    }
                    .width(min: 160, ideal: 280)

                    TableColumn("Artist", value: \TrackRow.track.artist) { row in
                        PlaylistTableArtistCell(artist: row.track.artist)
                    }
                    .width(min: 100, ideal: 180)

                    TableColumn("Album", value: \TrackRow.track.album) { row in
                        PlaylistTableAlbumCell(album: row.track.album)
                    }
                    .width(min: 100, ideal: 180)

                    TableColumn("Time", value: \TrackRow.track.durationSortKey) { row in
                        PlaylistTableTimeCell(formattedDuration: row.track.formattedDuration)
                    }
                    .width(54)

                    TableColumn("Format", value: \TrackRow.track.format) { row in
                        PlaylistTableFormatCell(track: row.track, formatColor: formatColor)
                    }
                    .width(60)
                }

                Group {
                    TableColumn("Genre", value: \TrackRow.track.genreSortKey) { row in
                        PlaylistTableGenreCell(genre: row.track.genre)
                    }
                    .width(min: 70, ideal: 110)

                    TableColumn("Year", value: \TrackRow.track.yearSortKey) { row in
                        PlaylistTableYearCell(year: row.track.year)
                    }
                    .width(48)

                    TableColumn("Energy", value: \TrackRow.track.energySortKey) { row in
                        PlaylistTableEnergyCell(level: row.track.energyBucket)
                    }
                    .width(56)

                    TableColumn("Dance", value: \TrackRow.track.danceabilitySortKey) { row in
                        DanceabilitySteps(score: row.track.danceability)
                    }
                    .width(56)

                    TableColumn("Added", value: \TrackRow.track.dateAddedSortKey) { row in
                        PlaylistTableAddedCell(dateAdded: row.track.dateAdded, formatDate: formatDateAdded)
                    }
                    .width(78)
                }
            } rows: {
                ForEach(cachedRows) { row in
                    TableRow(row)
                        .draggable(TrackDragData(trackId: row.id, sourcePlaylistId: playlist.id))
                }
                .dropDestination(for: TrackDragData.self) { index, items in
                    _ = handleDrop(items: items, destinationIndex: index)
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
                    },
                    playlist: playlist,
                    onRemoveFromPlaylist: {
                        Task { await onRemoveTracks(selectedIDs) }
                    }
                )
            } primaryAction: { selectedIDs in
                if let trackID = selectedIDs.first,
                   let track = viewModel.displayedTracks.first(where: { $0.id == trackID }) {
                    onTrackDoubleClick?(track)
                }
            }
        }
        .task {
            updateCachedRows()
        }
        .onChange(of: viewModel.displayedTracks) {
            updateCachedRows()
        }
        .onChange(of: sortOrder) {
            updateCachedRows()
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(items: [TrackDragData], destinationIndex: Int) -> Bool {
        guard !items.isEmpty else { return false }
        
        let trackIds = items.map { $0.trackId }
        
        // Target index in the full viewModel.tracks array
        let targetIndex = getTargetTrackIndex(for: destinationIndex)

        // Check if drag originates from inside the same playlist
        let isInternalDrag = items.allSatisfy { $0.sourcePlaylistId == playlist.id }

        Task {
            if isInternalDrag && isDefaultOrder {
                // Perform track move/reordering
                for item in items {
                    if let sourceIndex = viewModel.tracks.firstIndex(where: { $0.id == item.trackId }) {
                        // Adjust targetIndex dynamically if items move forward/backward
                        let destination = sourceIndex < targetIndex ? targetIndex : targetIndex
                        await viewModel.moveTrack(from: sourceIndex, to: destination)
                    }
                }
            } else {
                // Perform insertion of tracks from outside
                await viewModel.addTracks(trackIds, at: targetIndex)
            }
        }
        return true
    }

    /// Map visual table insertion index to the actual index in the full viewModel.tracks array.
    private func getTargetTrackIndex(for destinationIndex: Int) -> Int {
        if cachedRows.isEmpty {
            return 0
        }
        if destinationIndex == 0 {
            let firstRowTrackId = cachedRows[0].track.id
            return viewModel.tracks.firstIndex(where: { $0.id == firstRowTrackId }) ?? 0
        }
        if destinationIndex >= cachedRows.count {
            let lastRowTrackId = cachedRows.last!.track.id
            if let lastIdx = viewModel.tracks.firstIndex(where: { $0.id == lastRowTrackId }) {
                return lastIdx + 1
            }
            return viewModel.tracks.count
        }
        let targetRowTrackId = cachedRows[destinationIndex].track.id
        return viewModel.tracks.firstIndex(where: { $0.id == targetRowTrackId }) ?? destinationIndex
    }

    // MARK: - Helpers

    private func isNowPlaying(_ track: Track) -> Bool {
        guard let playbackVM = container.playbackViewModel,
              let currentTrack = playbackVM.currentTrack,
              let currentID = currentTrack.id,
              let trackID = track.id else {
            return false
        }
        return currentID == trackID && playbackVM.isPlaying
    }

    private func formatColor(_ format: String) -> Color {
        switch format.lowercased() {
        case "flac", "alac": return .mlmSuccess
        case "mp3": return .mlmActive
        case "aac", "m4a": return .mlmWarning
        case "ogg": return .mlmAccent
        default: return .mlmInkMuted
        }
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

    private func updateCachedRows() {
        let mapped = viewModel.displayedTracks
            .enumerated()
            .compactMap { idx, t in t.id.map { TrackRow(index: idx + 1, id: $0, track: t) } }
        self.cachedRows = mapped.sorted(using: sortOrder)
    }
}

// MARK: - Helper Cell Views for Compiler Performance

private struct PlaylistTableIndexCell: View {
    let index: Int
    var body: some View {
        Text("\(index)")
            .font(MLMFont.dataSmall)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct PlaylistTableTitleCell: View {
    let track: Track
    let isPlaying: Bool
    var body: some View {
        HStack(spacing: 8) {
            TrackCoverView(trackId: track.id ?? 0, size: .small, cornerRadius: 4)
                .frame(width: 18, height: 18)

            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .imageScale(.small)
                    .foregroundStyle(Color.mlmAccent)
                    .symbolEffect(.variableColor, isActive: true)
            }
            Text(track.title)
                .font(MLMFont.tableCell)
                .lineLimit(1)
        }
    }
}

private struct PlaylistTableArtistCell: View {
    let artist: String
    var body: some View {
        Text(artist)
            .font(MLMFont.tableCell)
            .lineLimit(1)
    }
}

private struct PlaylistTableAlbumCell: View {
    let album: String
    var body: some View {
        Text(album)
            .font(MLMFont.tableCell)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct PlaylistTableTimeCell: View {
    let formattedDuration: String
    var body: some View {
        Text(formattedDuration)
            .font(MLMFont.dataSmall)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

private struct PlaylistTableFormatCell: View {
    let track: Track
    let formatColor: (String) -> Color
    var body: some View {
        Text(track.isRemote ? "Stream" : track.format.uppercased())
            .font(MLMFont.badge)
            .foregroundColor(formatColor(track.format))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(formatColor(track.format).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct PlaylistTableGenreCell: View {
    let genre: String?
    var body: some View {
        Text(genre ?? "—")
            .font(MLMFont.tableCell)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct PlaylistTableYearCell: View {
    let year: Int?
    var body: some View {
        Text(year.map { "\($0)" } ?? "—")
            .font(MLMFont.dataSmall)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

private struct PlaylistTableEnergyCell: View {
    let level: Int?
    var body: some View {
        EnergyBars(level: level)
    }
}

private struct PlaylistTableAddedCell: View {
    let dateAdded: String?
    let formatDate: (String?) -> String
    var body: some View {
        Text(formatDate(dateAdded))
            .font(MLMFont.tableCell)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
