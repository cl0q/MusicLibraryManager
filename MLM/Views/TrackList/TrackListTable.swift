import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// **The** track table (V-TRACK-TABLE, UC-TABLE-01…22): a native `Table` with `Set<Track.ID>`
/// selection, sortable columns, per-view column customization, one context menu + primary
/// action, type-select, ⌫ / ⌘C on the focused list. Every track list hosts it
/// (`TrackListConfiguration` documents how).
///
/// Structure — so that a selection change or an arrow step never re-evaluates 13,000 rows:
/// - `TrackTableCore` builds the `Table`; it reads the rows, not the selection's value.
/// - `TrackTablePublisher` (a modifier) reads the selection and publishes the focused values,
///   the status-bar text and Info's selection — work proportional to the selection.
/// - `TrackTableLive` (playing track, running downloads, the drive) is an observable read
///   only by the cells.
struct TrackListTable<EmptyContent: View>: View {
    @Bindable var model: TrackListModel
    let configuration: TrackListConfiguration
    let emptyContent: EmptyContent

    @SceneStorage private var columnCustomization: TableColumnCustomization<TrackRow>
    @SceneStorage private var storedSort: String
    @State private var live = TrackTableLive()
    @State private var didRestoreSort = false

    @Environment(\.container) private var container
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(NavigationModel.self) private var navigation: NavigationModel?

    init(
        model: TrackListModel,
        configuration: TrackListConfiguration,
        @ViewBuilder emptyContent: () -> EmptyContent
    ) {
        self.model = model
        self.configuration = configuration
        self.emptyContent = emptyContent()
        _columnCustomization = SceneStorage(wrappedValue: TableColumnCustomization<TrackRow>(),
                                            "trackTable.columns.\(configuration.persistenceKey)")
        _storedSort = SceneStorage(wrappedValue: "", "trackTable.sort.\(configuration.sortPersistenceKey ?? configuration.persistenceKey)")
    }

    private var actions: TrackListActions {
        TrackListActions(model: model, configuration: configuration, live: live,
                         statusBar: statusBar, undo: undo, shell: shell, container: container,
                         navigation: navigation)
    }

    var body: some View {
        TrackTableCore(
            model: model,
            configuration: configuration,
            columnCustomization: $columnCustomization,
            sortOrder: sortBinding,
            actions: actions,
            live: live
        )
        .environment(live)
        .environment(\.trackTableCellOptions, TrackTableCellOptions(
            showsFailureDetail: configuration.showsFailureDetail,
            dimsPosition: configuration.hasContainerOrder && !(model.sortOrder?.isContainerOrder ?? true),
            openAlbum: configuration.openAlbum
        ))
        .overlay {
            if model.isLoaded, model.rows.isEmpty {
                emptyContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            reorderHint
        }
        .modifier(TrackTablePublisher(
            model: model,
            configuration: configuration,
            live: live,
            actions: actions,
            viewOptions: viewOptions
        ))
        // The selection bar of the scaffold around this table, if it hosts one (W2-G).
        .modifier(TrackSelectionBarRegistration(model: model, configuration: configuration, live: live))
        .background {
            TrackTableLiveObserver(live: live)
        }
        // Go to Current Track ⌘L selects the playing row here when this is its list (W2-C).
        .background {
            TrackListRevealTaker(model: model, configuration: configuration)
        }
        .task {
            TrackMenuSources.shared.loadIfNeeded(container: container)
            guard !didRestoreSort else { return }
            didRestoreSort = true
            let stored = TrackSortOrder(rawValue: storedSort)
            let order = configuration.isSortable ? (stored ?? configuration.defaultSort) : configuration.defaultSort
            await model.setSortOrder(order)
        }
    }

    // MARK: Sort (UC-TABLE-04)

    private var sortBinding: Binding<[KeyPathComparator<TrackRow>]> {
        Binding(
            get: { model.sortOrder.map { [$0.comparator] } ?? [] },
            set: { comparators in
                guard configuration.isSortable else { return }
                setSort(comparators.first.flatMap(TrackSortOrder.init))
            }
        )
    }

    private func setSort(_ order: TrackSortOrder?) {
        storedSort = order?.rawValue ?? ""
        Task { await model.setSortOrder(order) }
    }

    // MARK: Columns / Sort By for the View menu

    private var viewOptions: TrackTableViewOptions {
        let available = configuration.columns
        let customization = $columnCustomization
        let hideable = TrackColumnID.hideableColumns.filter(available.contains)
        let columns = hideable.map { id -> (id: TrackColumnID, isVisible: Bool) in
            (id, Self.isVisible(id, in: columnCustomization))
        }
        return TrackTableViewOptions(
            columns: columns,
            setColumnVisible: { id, visible in
                customization.wrappedValue[visibility: id.rawValue] = visible ? .visible : .hidden
            },
            sortColumns: available.filter { $0 != .number && ($0 == .title || Self.isVisible($0, in: columnCustomization)) },
            hasContainerOrder: configuration.hasContainerOrder,
            isSortable: configuration.isSortable,
            sortOrder: model.sortOrder,
            setSortOrder: { order in setSort(order) }
        )
    }

    static func isVisible(_ id: TrackColumnID, in customization: TableColumnCustomization<TrackRow>) -> Bool {
        switch customization[visibility: id.rawValue] {
        case .visible: true
        case .hidden: false
        default: id.isVisibleByDefault
        }
    }

    // MARK: Reorder hint (UC-TABLE-05)

    @ViewBuilder
    private var reorderHint: some View {
        if configuration.hasContainerOrder, let order = model.sortOrder, !order.isContainerOrder {
            HStack(spacing: Spacing.xs) {
                Text("Sorted by \(order.column.title) — reordering is off")
                    .foregroundStyle(.secondary)
                Button("Sort by #") { setSort(TrackSortOrder(column: .number, ascending: true)) }
                    .buttonStyle(.link)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xxs)
            .background(.background)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

// MARK: - The table

private struct TrackTableCore: View {
    @Bindable var model: TrackListModel
    let configuration: TrackListConfiguration
    @Binding var columnCustomization: TableColumnCustomization<TrackRow>
    let sortOrder: Binding<[KeyPathComparator<TrackRow>]>
    let actions: TrackListActions
    let live: TrackTableLive

    var body: some View {
        ScrollViewReader { proxy in
            table
                .onChange(of: model.scrollTarget) { _, target in
                    // Instant, never animated (UC-MOTION-03).
                    if let target { proxy.scrollTo(target.rowID, anchor: .center) }
                }
        }
    }

    private var table: some View {
        Table(of: TrackRow.self, selection: $model.selection, sortOrder: sortOrder, columnCustomization: $columnCustomization) {
            TableColumnForEach(configuration.columns) { column in
                TrackTableColumns.column(column)
            }
        } rows: {
            ForEach(model.isLoaded ? model.rows : TrackTablePlaceholders.rows) { row in
                // Ids + the file URL of a local, reachable track (UC-DND-01/02), built when the
                // drag starts (the payload is an autoclosure): no disk access. A drag of a
                // selected row carries every selected row, in display order (one item each).
                TableRow(row)
                    .draggable(dragItem(row))
            }
            .onInsert(of: configuration.onInsert == nil ? [] : TrackListConfiguration.insertableTypes) { index, providers in
                configuration.onInsert?(index, providers, model.rows)
            }
        }
        // Out of MLM a drag copies — Finder, Mail and DJ software never move a library file.
        .dragConfiguration(TrackDragConfiguration.rows)
        .contextMenu(forSelectionType: Int64.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            actions.primary(ids)
        }
        // ⌫ removes the selected rows that are shown — never ones a search is hiding (S5).
        .onDeleteCommand(perform: configuration.removeFromContainer.map { remove in
            { remove(Set(model.selectedRows().map(\.id))) }
        })
        .onCopyCommand { actions.copyItems() }
        // Space previews, Esc ends it, ←/→ seek while previewing — only while this table has
        // keyboard focus (UC-KEY-01/04/05, W2-C). Never Play/Pause.
        .modifier(TrackListPreviewKeys(actions: actions))
        .alternatingRowBackgrounds()
        .redacted(reason: model.isLoaded ? [] : .placeholder)
        .allowsHitTesting(model.isLoaded)
        .accessibilityIdentifier(configuration.accessibilityID)
    }

    @Environment(\.container) private var container

    private func dragItem(_ row: TrackRow) -> TrackDragItem {
        TrackDragContext.current(container).item(for: row, sourcePlaylistID: configuration.dragSourcePlaylistID)
            ?? TrackDragItem(trackId: row.id, sourcePlaylistId: configuration.dragSourcePlaylistID, libraryId: nil)
    }

    @ViewBuilder
    private func menu(for ids: Set<Int64>) -> some View {
        let rows = model.selectedRows(ids)
        if !rows.isEmpty {
            let context = TrackMenuContext(
                container: configuration.listContext.container,
                canActivate: configuration.activate != nil,
                canRemoveFromContainer: configuration.removeFromContainer != nil,
                canAddToSyncProfile: configuration.canAddToSyncProfile,
                extras: configuration.menuExtras?.items(rows) ?? .none
            )
            let state = live.state
            let menuModel = TrackMenuModel.make(subject: TrackMenuSubject(rows: rows, live: state), context: context)
            let sources = TrackMenuSources.shared
            TrackMenu(
                model: menuModel,
                rows: rows,
                actions: actions,
                playlists: sources.playlists.filter { playlist in
                    if case .playlist(let id, _) = configuration.listContext.container { return playlist.id != id }
                    return true
                },
                syncProfiles: sources.syncProfiles,
                offlineVolumeName: state.offlineVolumeName
            )
        }
    }
}

/// The columns, built uniformly so `TableColumnForEach` can host any subset in table order.
enum TrackTableColumns {
    @MainActor
    static func column(_ id: TrackColumnID) -> some TableColumnContent<TrackRow, KeyPathComparator<TrackRow>> {
        let width = id.width
        return base(id)
            .width(min: width.min, ideal: width.ideal, max: width.max)
            .alignment(id.isNumeric ? .numeric : .leading)
            .customizationID(id.rawValue)
            .defaultVisibility(id.isVisibleByDefault ? .visible : .hidden)
            .disabledCustomizationBehavior(id.isHideable ? [] : .visibility)
    }

    private static func base(_ id: TrackColumnID) -> TableColumn<TrackRow, KeyPathComparator<TrackRow>, TrackCell, Text> {
        switch id {
        case .number: TableColumn(id.title, value: \TrackRow.position) { TrackCell(column: id, row: $0) }
        case .title: TableColumn(id.title, value: \TrackRow.titleSortKey) { TrackCell(column: id, row: $0) }
        case .artist: TableColumn(id.title, value: \TrackRow.artistSortKey) { TrackCell(column: id, row: $0) }
        case .album: TableColumn(id.title, value: \TrackRow.albumSortKey) { TrackCell(column: id, row: $0) }
        case .time: TableColumn(id.title, value: \TrackRow.durationSortKey) { TrackCell(column: id, row: $0) }
        case .bpm: TableColumn(id.title, value: \TrackRow.bpmSortKey) { TrackCell(column: id, row: $0) }
        case .energy: TableColumn(id.title, value: \TrackRow.energySortKey) { TrackCell(column: id, row: $0) }
        case .dance: TableColumn(id.title, value: \TrackRow.danceSortKey) { TrackCell(column: id, row: $0) }
        case .genre: TableColumn(id.title, value: \TrackRow.genreSortKey) { TrackCell(column: id, row: $0) }
        case .year: TableColumn(id.title, value: \TrackRow.yearSortKey) { TrackCell(column: id, row: $0) }
        case .format: TableColumn(id.title, value: \TrackRow.formatSortKey) { TrackCell(column: id, row: $0) }
        case .kbps: TableColumn(id.title, value: \TrackRow.bitrateSortKey) { TrackCell(column: id, row: $0) }
        case .added: TableColumn(id.title, value: \TrackRow.addedSortKey) { TrackCell(column: id, row: $0) }
        case .status: TableColumn(id.title, value: \TrackRow.statusSortKey) { TrackCell(column: id, row: $0) }
        case .match: TableColumn(id.title, value: \TrackRow.matchSortKey) { TrackCell(column: id, row: $0) }
        case .suggestion: TableColumn(id.title, value: \TrackRow.suggestionSortKey) { TrackCell(column: id, row: $0) }
        case .version: TableColumn(id.title, value: \TrackRow.versionSortKey) { TrackCell(column: id, row: $0) }
        case .location: TableColumn(id.title, value: \TrackRow.locationSortKey) { TrackCell(column: id, row: $0) }
        case .usedIn: TableColumn(id.title, value: \TrackRow.usedInSortKey) { TrackCell(column: id, row: $0) }
        }
    }
}

/// Redacted rows of the first load (UC-TABLE-09) — never a full-pane spinner.
enum TrackTablePlaceholders {
    static let rows: [TrackRow] = {
        let tracks = (1...14).map { index -> Track in
            var track = Track(artist: "Placeholder Artist", album: "Placeholder Album",
                              title: "Placeholder title \(index)", format: "m4a", originalPath: "placeholder://\(index)")
            track.id = -Int64(index)
            track.duration = 200
            return track
        }
        return TrackRowBuilder.build(tracks)
    }()
}

// MARK: - Publishing the selection

/// Reads the selection (O(selection)) and publishes `FocusedValues.trackSelection`, the View
/// menu's options, the status-bar text (UC-STATUS-02/03) and Info's selection (W2-E seam).
/// Also applied by the Folders outline (W3-FOLD), whose track rows are a `TrackListModel` too.
struct TrackTablePublisher: ViewModifier {
    let model: TrackListModel
    let configuration: TrackListConfiguration
    let live: TrackTableLive
    let actions: TrackListActions
    let viewOptions: TrackTableViewOptions
    /// Published instead of the rows' own selection when set — Folders, where a selected folder
    /// stands for its tracks in the Track menu (UC-MENU-05, W3-FOLD).
    var selectionOverride: TrackSelection? = nil

    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @Environment(\.container) private var container

    /// The kept-alive All Tracks table is in the window while another place shows (opacity 0).
    /// Hidden, it publishes nothing, writes nothing into Info's selection and takes no keys.
    private var isVisiblePlace: Bool {
        TrackTableVisibility.isVisible(
            isAllTracksTable: configuration.listContext.isAllTracksTable,
            allTracksVisible: navigation?.isAllTracksVisible ?? true,
            isSearching: container.searchCoordinator.isPresented
        )
    }

    func body(content: Content) -> some View {
        let visible = isVisiblePlace
        let selected = model.selectedRows()
        let summary = TrackSelectionSummary(rows: selected, container: configuration.listContext.container, live: live.state)
        content
            .disabled(!visible)
            .focusedValue(\.trackSelection, visible ? selection(summary: summary) : nil)
            .focusedValue(\.trackTableViewOptions, visible ? viewOptions : nil)
            .statusBarText(configuration.publishesStatusText ? statusText(selected) : nil)
            .onChange(of: model.selection) { _, _ in
                guard isVisiblePlace else { return }
                InspectedTrackSelection.shared.update(model.selectedRows().map(\.id), from: configuration.persistenceKey)
                // A running preview moves with the selection (UC-KEY-06).
                actions.previewSelectionDidChange()
            }
            .onChange(of: visible) { _, nowVisible in
                if !nowVisible {
                    TrackTableVisibility.resignTableFocus()
                    // Its preview can't be stopped from a list nobody sees (S4).
                    actions.previewOwnerGone()
                }
            }
            .onDisappear { actions.previewOwnerGone() }
    }

    private func selection(summary: TrackSelectionSummary) -> TrackSelection {
        if let selectionOverride { return selectionOverride }
        let model = self.model
        let sources = TrackMenuSources.shared
        let configuration = self.configuration
        let actions = self.actions
        return TrackSelection(
            selectedIDs: model.selection,
            summary: summary,
            context: configuration.listContext,
            hasPlayableRows: model.hasPlayableRows(live: live.state),
            rowsToken: model.rowsToken,
            target: TrackCommandTarget(
                activate: configuration.activate,
                // Track ▸ Remove from ‹Container› acts on the shown selected rows only (S5).
                removeFromContainer: configuration.removeFromContainer.map { remove in
                    { ids in remove(Set(model.selectedRows(ids).map(\.id))) }
                },
                deselectAll: { model.selection = [] },
                playlists: sources.playlists.filter { playlist in
                    if case .playlist(let id, _) = configuration.listContext.container { return playlist.id != id }
                    return true
                },
                syncProfiles: sources.syncProfiles,
                addToSyncProfile: { profile, ids in
                    actions.addToSyncProfile(profile, model.selectedRows(ids))
                },
                preview: { actions.preview() },
                recordOrigin: { actions.recordPlaybackOrigin(trackID: nil) }
            ),
            rows: { model.tracks }
        )
    }

    /// `14 selected · 52 min`, else `12,935 tracks · 38 days`.
    private func statusText(_ selected: [TrackRow]) -> String? {
        guard model.isLoaded else { return nil }
        if !selected.isEmpty {
            let seconds = selected.reduce(0) { $0 + max($1.track.duration ?? 0, 0) }
            return "\(selected.count.formatted(.number)) selected · \(TrackDurationText.total(seconds))"
        }
        let totals = configuration.totals ?? TrackListTotals(count: model.rows.count, duration: model.totalDuration)
        return "\(StatusBarText.tracks(totals.count)) · \(TrackDurationText.total(totals.duration))"
    }
}

// MARK: - Live state

/// Watches playback, downloads and the drive; writes `TrackTableLive.state` only when the
/// derived value changes (download progress ticks don't reach the rows). Also used by the
/// Folders outline (W3-FOLD).
struct TrackTableLiveObserver: View {
    let live: TrackTableLive
    @Environment(\.container) private var container

    var body: some View {
        let state = currentState
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { apply(state) }
            .onChange(of: state) { _, new in apply(new) }
    }

    private var currentState: TrackTableLiveState {
        let playback = container.playbackViewModel
        let drive = LibraryDriveState.current(container)
        var downloading: Set<Int64> = []
        if let downloads = container.downloadViewModel, downloads.isDownloading {
            for item in downloads.queueItems where [.queued, .downloading, .transcoding].contains(item.status) {
                downloading.insert(item.trackId)
            }
        }
        return TrackTableLiveState(
            nowPlayingID: playback?.currentTrack?.id,
            // The main track's own state: a preview pauses it (W2-C).
            isPlaying: playback?.isMainPlaying ?? false,
            activeDownloadIDs: downloading,
            offlineVolumePath: drive.isOffline ? container.mountObserver?.libraryVolumePath : nil,
            offlineVolumeName: drive.isOffline ? drive.volumeName : nil
        )
    }

    private func apply(_ state: TrackTableLiveState) {
        if live.state != state { live.state = state }
    }
}

// MARK: - Visibility of kept-alive tables

enum TrackTableVisibility {
    /// Only the All Tracks table is kept alive while hidden; every other table exists only
    /// while its place shows.
    static func isVisible(isAllTracksTable: Bool, allTracksVisible: Bool, isSearching: Bool) -> Bool {
        !isAllTracksTable || (allTracksVisible && !isSearching)
    }

    /// A table that just became hidden must not keep the keyboard: ↩, ⌘A and the arrows would
    /// act on rows nobody sees. The hidden table is disabled; if it still holds first
    /// responder, the window's first responder is cleared.
    @MainActor
    static func resignTableFocus() {
        guard let window = NSApp.keyWindow, window.firstResponder is NSTableView else { return }
        window.makeFirstResponder(nil)
    }
}

// MARK: - Go to Current Track (W2-C)

/// Takes a `TrackListReveal` request meant for this list: once the row is shown, select it
/// and scroll it into view. Reads the rows only while a request is pending for this list.
private struct TrackListRevealTaker: View {
    let model: TrackListModel
    let configuration: TrackListConfiguration
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?

    var body: some View {
        let request = TrackListReveal.shared.request.flatMap { request in
            request.matches(listKey: configuration.persistenceKey, container: configuration.listContext.container) ? request : nil
        }
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: RevealKey(requestID: request?.id, rowsLoaded: request == nil ? 0 : model.rows.count)) {
                guard let request, model.isLoaded else { return }
                if model.row(id: request.trackID) != nil {
                    model.selection = [request.trackID]
                    model.scrollTo(request.trackID)
                    TrackListReveal.shared.done(request.id)
                    return
                }
                // Loaded without the row: give a scope switch or reload a moment, then say why
                // and end the request (W2-C review S6). A new row count restarts this task.
                try? await Task.sleep(for: TrackListReveal.absentGrace)
                guard !Task.isCancelled, TrackListReveal.shared.request?.id == request.id,
                      model.row(id: request.trackID) == nil else { return }
                TrackListReveal.shared.done(request.id)
                statusBar?.post(TrackListReveal.absentMessage(title: request.title))
            }
    }

    private struct RevealKey: Equatable {
        let requestID: UUID?
        let rowsLoaded: Int
    }
}
