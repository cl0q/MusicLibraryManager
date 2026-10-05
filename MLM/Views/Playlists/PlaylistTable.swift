import Foundation
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
    var onTrackDoubleClick: ((Track, [Track]) -> Void)?
    var onRemoveTracks: (Set<Int64>) async -> Void

    @Environment(\.container) private var container

    /// Identifiable row wrapper with a 1-based natural index to represent
    /// position inside the playlist.
    struct TrackRow: Identifiable {
        let index: Int
        let id: Int64
        let track: Track
        let isFailed: Bool
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
                            .opacity(row.isFailed ? 0.6 : 1)
                    }
                    .width(28)

                    TableColumn("Title", value: \TrackRow.track.title) { row in
                        PlaylistTableTitleCell(track: row.track, isPlaying: isNowPlaying(row.track))
                            .opacity(row.isFailed ? 0.6 : 1)
                    }
                    .width(min: 160, ideal: 280)

                    TableColumn("Artist", value: \TrackRow.track.artist) { row in
                        PlaylistTableArtistCell(artist: row.track.artist)
                            .opacity(row.isFailed ? 0.6 : 1)
                    }
                    .width(min: 100, ideal: 180)

                    TableColumn("Album", value: \TrackRow.track.album) { row in
                        PlaylistTableAlbumCell(album: row.track.album)
                            .opacity(row.isFailed ? 0.6 : 1)
                    }
                    .width(min: 100, ideal: 180)

                    TableColumn("Time", value: \TrackRow.track.durationSortKey) { row in
                        PlaylistTableTimeCell(formattedDuration: row.track.formattedDuration)
                            .opacity(row.isFailed ? 0.6 : 1)
                    }
                    .width(54)

                    TableColumn("Format", value: \TrackRow.track.format) { row in
                        PlaylistTableFormatCell(track: row.track, formatColor: formatColor)
                            .opacity(row.isFailed ? 0.6 : 1)
                    }
                    .width(60)

                    TableColumn("Status") { row in
                        PlaylistTableStatusCell(availability: availability(for: row.track))
                            .opacity(row.isFailed ? 0.6 : 1)
                    }
                    .width(90)
                }

                Group {
                    TableColumn("Genre", value: \TrackRow.track.genreSortKey) { row in
                        PlaylistTableGenreCell(genre: row.track.genre)
                            .opacity(row.isFailed ? 0.6 : 1)
                    }
                    .width(min: 70, ideal: 110)

                    TableColumn("Year", value: \TrackRow.track.yearSortKey) { row in
                        PlaylistTableYearCell(year: row.track.year)
                            .opacity(row.isFailed ? 0.6 : 1)
                    }
                    .width(48)

                    TableColumn("Energy", value: \TrackRow.track.energySortKey) { row in
                        PlaylistTableEnergyCell(level: row.track.energyBucket)
                            .opacity(row.isFailed ? 0.6 : 1)
                    }
                    .width(56)

                    TableColumn("Dance", value: \TrackRow.track.danceabilitySortKey) { row in
                        DanceabilitySteps(score: row.track.danceability)
                            .opacity(row.isFailed ? 0.6 : 1)
                    }
                    .width(56)

                    TableColumn("Added", value: \TrackRow.track.dateAddedSortKey) { row in
                        PlaylistTableAddedCell(dateAdded: row.track.dateAdded, formatDate: formatDateAdded)
                            .opacity(row.isFailed ? 0.6 : 1)
                    }
                    .width(78)
                }
            } rows: {
                ForEach(cachedRows) { row in
                    TableRow(row)
                        .draggable(TrackDragData(trackId: row.id, sourcePlaylistId: playlist.id))
                }
                .onInsert(of: [.trackDrag]) { insertionIndex, providers in
                    handleInsert(at: insertionIndex, providers: providers)
                }
            }
            .accessibilityIdentifier("playlist_track_table")
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
                   let track = viewModel.displayedTracks.first(where: { $0.id == trackID }),
                   availability(for: track) == .local {
                    onTrackDoubleClick?(track, viewModel.displayedTracks)
                }
            }
            // The menu bar's Track commands act on this playlist while it has focus (W1-2).
            .focusedValue(\.trackSelection, menuSelection)
        }
        .task {
            updateCachedRows()
        }
        .onChange(of: viewModel.displayedTracks) {
            updateCachedRows()
        }
        .onChange(of: viewModel.availabilityByTrackID) {
            updateCachedRows()
        }
        .onChange(of: sortOrder) {
            updateCachedRows()
        }
    }

    /// This playlist as the Track menu sees it (`TrackSelection`): rows in the order shown,
    /// `Remove from “‹name›”` through the page's removal flow.
    private var menuSelection: TrackSelection {
        let viewModel = self.viewModel
        let onRemoveTracks = self.onRemoveTracks
        let container = self.container
        return TrackSelection(
            selectedIDs: viewModel.selectedTrackIDs,
            rows: cachedRows,
            id: \.id,
            isPlayable: { $0.track.isLocal },
            track: \.track,
            context: playlist.id.map { .playlist(id: $0, name: playlist.name) } ?? .unnamed,
            target: TrackCommandTarget(
                activate: onTrackDoubleClick,
                removeFromContainer: { ids in Task { await onRemoveTracks(ids) } },
                deselectAll: { viewModel.selectedTrackIDs = [] },
                playlists: availablePlaylists.filter { $0.id != playlist.id },
                syncProfiles: availableSyncProfiles,
                addToSyncProfile: { profile, ids in
                    Task {
                        container.syncViewModel?.selectedProfile = profile
                        await container.syncViewModel?.addTracks(Array(ids))
                    }
                }
            )
        )
    }

    // MARK: - Insert Handling

    private func handleInsert(at insertionIndex: Int, providers: [NSItemProvider]) {
        Task { @MainActor in
            var payloads: [TrackDragData] = []
            for provider in providers {
                let payload: TrackDragData? = await withCheckedContinuation { (continuation: CheckedContinuation<TrackDragData?, Never>) in
                    _ = provider.loadTransferable(type: TrackDragData.self) { result in
                        continuation.resume(returning: try? result.get())
                    }
                }
                if let payload {
                    payloads.append(payload)
                }
            }
            guard !payloads.isEmpty else { return }

            let draggedIDs = payloads.map(\.trackId)
            let targetIndex = getTargetTrackIndex(for: insertionIndex)
            let allMembers = draggedIDs.allSatisfy { id in viewModel.tracks.contains { $0.id == id } }

            // Internal-only drags are suppressed while sorted or filtered —
            // the custom order is meaningless in those states.
            if allMembers {
                guard isDefaultOrder, viewModel.searchQuery.isEmpty else { return }
            }

            await viewModel.placeTracks(draggedIDs, at: targetIndex)
        }
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

    private func availability(for track: Track) -> TrackAvailability {
        viewModel.availability(for: track)
    }

    private func isFailed(_ track: Track) -> Bool {
        if case .failed = availability(for: track) { return true }
        return false
    }

    /// Format date_added for display (e.g., "2026-05-07" → "May 7").
    private func formatDateAdded(_ dateString: String?) -> String {
        Self.formatDateAddedShared(dateString)
    }

    // Shared formatters — DateFormatter init is expensive (~0.03ms each),
    // so reuse static instances across all rows instead of creating new ones per row.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static func formatDateAddedShared(_ dateString: String?) -> String {
        guard let dateString else { return "—" }
        if let date = isoFormatter.date(from: String(dateString.prefix(10))) {
            return displayFormatter.string(from: date)
        }
        return String(dateString.prefix(10))
    }

    private func updateCachedRows() {
        let displayed = viewModel.displayedTracks
        let mapped = displayed
            .enumerated()
            .compactMap { idx, track in
                track.id.map {
                    TrackRow(
                        index: idx + 1,
                        id: $0,
                        track: track,
                        isFailed: isFailed(track)
                    )
                }
            }
        self.cachedRows = mapped.sorted(using: sortOrder)
    }
}

// MARK: - Helper Cell Views for Compiler Performance

private struct PlaylistTableIndexCell: View {
    let index: Int
    var body: some View {
        Text("\(index)")
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
                .foregroundStyle(isPlaying ? Color.mlmAccent : Color.mlmInk)
        }
    }
}

private struct PlaylistTableArtistCell: View {
    let artist: String
    var body: some View {
        TrackMetadataText(artist, font: MLMFont.tableCell)
    }
}

private struct PlaylistTableAlbumCell: View {
    let album: String
    var body: some View {
        TrackMetadataText(album, font: MLMFont.tableCell, secondary: true)
    }
}

private struct PlaylistTableTimeCell: View {
    let formattedDuration: String
    var body: some View {
        Text(formattedDuration)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

private struct PlaylistTableFormatCell: View {
    let track: Track
    let formatColor: (String) -> Color
    var body: some View {
        let format = track.format.trimmingCharacters(in: .whitespacesAndNewlines)
        Text(format.isEmpty ? "—" : format.uppercased())
            .font(MLMFont.badge)
            .foregroundColor(formatColor(track.format))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(formatColor(track.format).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct PlaylistTableStatusCell: View {
    let availability: TrackAvailability

    var body: some View {
        Group {
            if let statusChip = StatusChip(availability: availability) {
                statusChip
            } else {
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
