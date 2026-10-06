import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The playlist detail's track table: the shared `TrackListTable` in its playlist context —
/// `#` column in playlist order, Added = added to this playlist (UC-TABLE-19), ⌫ removes from
/// the playlist as one undo step (UC-UNDO-06), drag-to-reorder and drops while in playlist
/// order, drops at the insertion line (W2-H) and the `Download failed` scope (W3-PL).
struct PlaylistTable: View {
    let playlist: Playlist
    @Bindable var viewModel: PlaylistDetailViewModel
    var onTrackDoubleClick: ((Track, [Track]) -> Void)?
    /// The `Download failed` scope (V-PLD.E14): only failed rows, each with its reason and the
    /// attempts left on a second line (UC-TABLE-13).
    var failedOnly = false

    @State private var list = TrackListModel(sortOrder: TrackSortOrder(column: .number, ascending: true))
    @Environment(UndoCenter.self) private var undo: UndoCenter?

    var body: some View {
        TrackListTable(model: list, configuration: configuration) {
            if !viewModel.searchFilter.isEmpty {
                ContentUnavailableView.search(text: viewModel.searchFilter.displayText)
            }
        }
        .task(id: loadKey) { await load() }
        .background { SelectionMirror(list: list, viewModel: viewModel) }
        // A file check changed persisted availability: reload in place.
        .onReceive(NotificationCenter.default.publisher(for: .trackAvailabilityDidChange)) { _ in
            Task { await viewModel.refresh() }
        }
        // A tag edit in Info (or its undo) changed track fields: reload in place.
        .onReceive(NotificationCenter.default.publisher(for: .trackMetadataDidChange)) { _ in
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
        .showingFailureDetail(failedOnly)
    }

    /// Reload when the playlist's tracks, the filter or the added dates change.
    private var loadKey: Int {
        var hasher = Hasher()
        hasher.combine(viewModel.tracks)
        hasher.combine(viewModel.displayedTracks.count)
        hasher.combine(viewModel.searchFilter)
        hasher.combine(viewModel.addedAtByTrackID.count)
        hasher.combine(failedOnly)
        return hasher.finalize()
    }

    private func load() async {
        var visible: Set<Int64>? = viewModel.searchFilter.isEmpty
            ? nil
            : Set(viewModel.displayedTracks.compactMap(\.id))
        if failedOnly {
            let failed = Set(viewModel.failedTracks.compactMap(\.id))
            visible = visible.map { $0.intersection(failed) } ?? failed
        }
        await list.setTracks(
            viewModel.tracks,
            context: TrackRowBuildContext(addedMeaning: .container, containerAddedDates: viewModel.addedAtByTrackID),
            visibleIDs: visible
        )
    }

    // MARK: - Reorder and drops (D-PLD-REORDER, D-PLD-INSERT, W2-H)

    @Environment(\.container) private var container
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?

    private var isPlaylistOrder: Bool {
        list.sortOrder?.isContainerOrder ?? true
    }

    /// The column the table is sorted by when it isn't in playlist order.
    private var sortedBy: String? {
        guard let order = list.sortOrder, !order.isContainerOrder else { return nil }
        return order.column.title
    }

    /// A drop at the insertion line: the matrix column "Playlist detail table". Tracks and
    /// playlists land at the line (or at the end while sorted) as one undo step with exact
    /// positions; Finder files import and land there; an M3U shows its preview; a link goes to
    /// Add from Link…. Reordering is off while sorted or filtered (UC-TABLE-05).
    private func handleInsert(at insertionIndex: Int, providers: [NSItemProvider], displayRows: [TrackRow]) {
        guard let playlistID = playlist.id else { return }
        let name = viewModel.playlist.name
        let target = DropTarget.playlistTable(id: playlistID, name: name, sortedBy: sortedBy)
        let order = viewModel.tracks.compactMap(\.id)
        let shown = displayRows.map(\.id)
        let isPlaylistOrder = self.isPlaylistOrder
        let isFiltered = !viewModel.searchFilter.isEmpty || failedOnly
        let sortedBy = self.sortedBy
        let performer = DropPerformer(container: container, shell: shell, statusBar: statusBar, undo: undo ?? .main)
        Task { @MainActor in
            guard let content = await DropLoader.load(providers) else { return }
            let decision = DropRules.decide(content, onto: target, context: DropContext.current(container))
            let place: ([Int64]) async -> Void = { ids in
                guard let edits = shell?.edits, let plan = PlaylistDropPlan.make(
                    trackIDs: ids, playlistOrder: order, displayRows: shown, insertionIndex: insertionIndex,
                    isPlaylistOrder: isPlaylistOrder, isFiltered: isFiltered
                ) else { return }
                if plan.kind == .append {
                    await edits.addTracks(plan.trackIDs, toPlaylist: playlistID,
                                          messageSuffix: sortedBy.map(DropWords.appendedWhileSorted) ?? "")
                } else {
                    await edits.placeTracks(plan, inPlaylist: playlistID, name: name)
                }
            }
            switch decision {
            case .placeTracks(let payload, _, _):
                await place(payload.trackIDs)
            case .placePlaylists(let ids, _, _):
                guard let edits = shell?.edits else { return }
                await place(await edits.tracks(ofPlaylists: ids))
            case .importFilesAndPlace(let urls, _, _):
                guard let shell else { return }
                let ids = await shell.importDropped(urls, intoPlaylist: name)
                if !ids.isEmpty { await place(ids) }
            default:
                performer.perform(decision)
            }
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

private extension TrackListConfiguration {
    /// The `Download failed` scope's second line under failed rows (UC-TABLE-13).
    func showingFailureDetail(_ shows: Bool) -> TrackListConfiguration {
        var copy = self
        copy.showsFailureDetail = shows
        return copy
    }
}

/// Mirrors the table's selection into the view model from a leaf, so a selection change never
/// re-evaluates the playlist table's body.
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
