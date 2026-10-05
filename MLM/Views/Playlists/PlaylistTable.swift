import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The playlist detail's track table: the shared `TrackListTable` in its playlist context —
/// `#` column in playlist order, Added = added to this playlist (UC-TABLE-19), ⌫ removes from
/// the playlist as one undo step (UC-UNDO-06), drag-to-reorder and drops while in playlist
/// order (today's reorder; W3-PL / W2-H extend it through `onInsert`).
struct PlaylistTable: View {
    let playlist: Playlist
    @Bindable var viewModel: PlaylistDetailViewModel
    var onTrackDoubleClick: ((Track, [Track]) -> Void)?

    @State private var list = TrackListModel(sortOrder: TrackSortOrder(column: .number, ascending: true))
    @Environment(UndoCenter.self) private var undo: UndoCenter?

    var body: some View {
        TrackListTable(model: list, configuration: configuration) {
            if !viewModel.searchQuery.isEmpty {
                ContentUnavailableView.search(text: viewModel.searchQuery)
            }
        }
        .task(id: loadKey) { await load() }
        .background { SelectionMirror(list: list, viewModel: viewModel) }
        // A file check changed persisted availability: reload in place.
        .onReceive(NotificationCenter.default.publisher(for: .trackAvailabilityDidChange)) { _ in
            Task { await viewModel.refresh() }
        }
    }

    private var configuration: TrackListConfiguration {
        let undo = self.undo
        let id = playlist.id ?? -1
        let name = viewModel.playlist.name
        return .playlist(
            id: id,
            name: name,
            activate: onTrackDoubleClick,
            remove: { ids in
                PlaylistTrackRemoval.remove(ids, fromPlaylist: id, name: name, undo: undo)
            },
            onInsert: { index, providers, rows in
                handleInsert(at: index, providers: providers, displayRows: rows)
            }
        )
    }

    /// Reload when the playlist's tracks, the filter or the added dates change.
    private var loadKey: Int {
        var hasher = Hasher()
        hasher.combine(viewModel.tracks)
        hasher.combine(viewModel.displayedTracks.count)
        hasher.combine(viewModel.searchQuery)
        hasher.combine(viewModel.addedAtByTrackID.count)
        return hasher.finalize()
    }

    private func load() async {
        let visible: Set<Int64>? = viewModel.searchQuery.isEmpty
            ? nil
            : Set(viewModel.displayedTracks.compactMap(\.id))
        await list.setTracks(
            viewModel.tracks,
            context: TrackRowBuildContext(addedMeaning: .container, containerAddedDates: viewModel.addedAtByTrackID),
            visibleIDs: visible
        )
    }

    // MARK: - Reorder and drops (kept from before W2-A)

    private var isPlaylistOrder: Bool {
        list.sortOrder?.isContainerOrder ?? true
    }

    private func handleInsert(at insertionIndex: Int, providers: [NSItemProvider], displayRows: [TrackRow]) {
        Task { @MainActor in
            var payloads: [TrackDragData] = []
            for provider in providers {
                let payload: TrackDragData? = await withCheckedContinuation { (continuation: CheckedContinuation<TrackDragData?, Never>) in
                    _ = provider.loadTransferable(type: TrackDragData.self) { result in
                        continuation.resume(returning: try? result.get())
                    }
                }
                if let payload { payloads.append(payload) }
            }
            guard !payloads.isEmpty else { return }

            let draggedIDs = payloads.map(\.trackId)
            let allMembers = draggedIDs.allSatisfy { id in viewModel.tracks.contains { $0.id == id } }
            // Reordering is off while sorted or filtered (UC-TABLE-05); drops from elsewhere
            // still land (at the end when sorted).
            if allMembers {
                guard isPlaylistOrder, viewModel.searchQuery.isEmpty else { return }
            }
            let target = isPlaylistOrder
                ? Self.targetTrackIndex(for: insertionIndex, displayRows: displayRows, tracks: viewModel.tracks)
                : viewModel.tracks.count
            await viewModel.placeTracks(draggedIDs, at: target)
        }
    }

    /// Maps a display insertion index to the index in the playlist's full track order.
    static func targetTrackIndex(for destinationIndex: Int, displayRows: [TrackRow], tracks: [Track]) -> Int {
        guard !displayRows.isEmpty else { return 0 }
        if destinationIndex <= 0 {
            return tracks.firstIndex { $0.id == displayRows[0].id } ?? 0
        }
        if destinationIndex >= displayRows.count {
            let last = displayRows[displayRows.count - 1].id
            return tracks.firstIndex { $0.id == last }.map { $0 + 1 } ?? tracks.count
        }
        let target = displayRows[destinationIndex].id
        return tracks.firstIndex { $0.id == target } ?? destinationIndex
    }
}

/// Mirrors the table's selection into the view model (the header's `Remove n` button) from a
/// leaf, so a selection change never re-evaluates the playlist table's body.
private struct SelectionMirror: View {
    let list: TrackListModel
    let viewModel: PlaylistDetailViewModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: list.selection) { _, _ in
                // Only rows that are shown: `Remove n` never touches rows a search hides (S5).
                let visible = Set(list.selectedRows().map(\.id))
                if viewModel.selectedTrackIDs != visible { viewModel.selectedTrackIDs = visible }
            }
    }
}
