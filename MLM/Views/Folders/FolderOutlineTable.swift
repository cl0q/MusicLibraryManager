import AppKit
import SwiftUI

// MARK: - The hierarchical table (V-FOLD.E04, DEC-024, UC-TABLE-01, UC-KIT-03)

/// One native `Table` of `FolderOutlineRow`s with `DisclosureTableRow`s (macOS 27 SDK:
/// `DisclosureTableRow(_:isExpanded:content:)`): folder rows with disclosure triangles, the
/// library tracks with the All Tracks columns, the files that aren't in the library, dimmed.
///
/// `TrackListTable` can't host it (its rows are `TrackRow`s, flat), so this is its own `Table`
/// whose track rows reuse the shared parts: `TrackCell` (every cell of a track row),
/// `TrackListModel` (selection, shown rows), `TrackListActions` (↩, menu items, Space),
/// `TrackMenu`, `TrackTablePublisher` (Track menu, View ▸ Columns / Sort By, Info), the
/// selection bar and the shared drag payload. Column visibility is its own (`folders`, per
/// UC-TABLE-03 a view keeps its columns).
struct FolderOutlineTable: View {
    @Bindable var model: FolderViewModel
    let configuration: TrackListConfiguration
    let actions: TrackListActions
    let folderActions: FolderActions
    let live: TrackTableLive

    @SceneStorage("trackTable.columns.folders") private var columnCustomization = TableColumnCustomization<FolderOutlineRow>()
    @SceneStorage("trackTable.sort.folders") private var storedSort = ""
    @State private var didRestoreSort = false
    @State private var typeSelect = TrackListPreviewKeys.TypeSelectClock()

    @Environment(\.container) private var container

    static let columns: [TrackColumnID] = TrackColumnID.standardColumns.filter { $0 != .number }

    var body: some View {
        ScrollViewReader { proxy in
            table
                .onChange(of: model.trackList.scrollTarget) { _, target in
                    if let target { proxy.scrollTo(target.rowID, anchor: .center) }
                }
        }
        .environment(live)
        .environment(\.trackTableCellOptions, TrackTableCellOptions())
        .modifier(TrackTablePublisher(model: model.trackList, configuration: configuration, live: live,
                                      actions: actions, viewOptions: viewOptions,
                                      selectionOverride: folderSelection))
        .onChange(of: model.trackList.selection) { _, _ in model.selectionDidChange() }
        .modifier(TrackSelectionBarRegistration(model: model.trackList, configuration: configuration, live: live))
        .focusedValue(\.folderOutlineKeys, outlineKeys)
        .background { TrackTableLiveObserver(live: live) }
        .task {
            TrackMenuSources.shared.loadIfNeeded(container: container)
            guard !didRestoreSort else { return }
            didRestoreSort = true
            if let stored = TrackSortOrder(rawValue: storedSort), stored.column != .number {
                model.setSortOrder(stored)
            }
        }
    }

    private var table: some View {
        Table(of: FolderOutlineRow.self, selection: Bindable(model.trackList).selection,
              sortOrder: sortBinding, columnCustomization: $columnCustomization) {
            TableColumnForEach(Self.columns) { column in
                FolderTableColumns.column(column)
            }
        } rows: {
            FolderOutlineRows(rows: model.outline.rows, model: model, folderActions: folderActions, dragContext: dragContext)
        }
        // Out of MLM a drag copies — Finder never moves a library file (UC-DND-02).
        .dragConfiguration(TrackDragConfiguration.rows)
        .contextMenu(forSelectionType: Int64.self) { ids in
            FolderOutlineMenu(ids: ids, model: model, actions: actions, folderActions: folderActions, live: live)
        } primaryAction: { ids in
            primary(ids)
        }
        .onCopyCommand { folderActions.copyItems(model.trackList.selection) }
        .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters), phases: .down) { press in
            if press.modifiers.isDisjoint(with: [.command, .control, .option]) { typeSelect.last = Date() }
            return .ignored
        }
        .onKeyPress(keys: [.space, .escape, .leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat, .up]) { press in
            handle(press)
        }
        .alternatingRowBackgrounds()
        // The outline's own root: Finder files dropped anywhere on it are imported there.
        .dropTarget(.folderRow(path: model.root, name: model.rootName), cornerRadius: 0)
        .accessibilityIdentifier("folders_outline_table")
    }

    private var dragContext: TrackDragContext { TrackDragContext.current(container) }

    /// With folders selected the Track menu acts on their tracks (UC-MENU-05): the same commands,
    /// the folders' tracks in display order as the selection.
    private var folderSelection: TrackSelection? {
        guard let resolved = model.folderSelectionTracks, resolved.selection == model.trackList.selection else { return nil }
        let tracks = resolved.tracks
        let rows = TrackRowBuilder.build(tracks)
        let actions = self.actions
        let configuration = self.configuration
        let model = self.model
        let sources = TrackMenuSources.shared
        return TrackSelection(
            selectedIDs: Set(tracks.compactMap(\.id)),
            summary: TrackSelectionSummary(rows: rows, container: configuration.listContext.container, live: live.state),
            context: configuration.listContext,
            hasPlayableRows: model.trackList.hasPlayableRows(live: live.state),
            rowsToken: rows.reduce(into: Hasher()) { $0.combine($1.id) }.finalize(),
            target: TrackCommandTarget(
                activate: configuration.activate,
                deselectAll: { model.trackList.selection = [] },
                playlists: sources.playlists,
                syncProfiles: sources.syncProfiles,
                addToSyncProfile: { profile, ids in actions.addToSyncProfile(profile, rows.filter { ids.contains($0.id) }) },
                preview: { actions.preview(rows) },
                recordOrigin: { actions.recordPlaybackOrigin(trackID: nil) }
            ),
            rows: { tracks }
        )
    }

    // MARK: Sort (within each folder, UC-TABLE-04)

    private var sortBinding: Binding<[KeyPathComparator<FolderOutlineRow>]> {
        Binding(
            get: { model.sortOrder.map { [FolderTableColumns.comparator($0)] } ?? [] },
            set: { comparators in
                setSort(comparators.first.flatMap(FolderTableColumns.order))
            }
        )
    }

    private func setSort(_ order: TrackSortOrder?) {
        let order = order ?? TrackSortOrder(column: .title, ascending: true)
        storedSort = order.rawValue
        model.setSortOrder(order)
    }

    private var viewOptions: TrackTableViewOptions {
        let customization = $columnCustomization
        let hideable = TrackColumnID.hideableColumns.filter(Self.columns.contains)
        return TrackTableViewOptions(
            columns: hideable.map { ($0, Self.isVisible($0, in: columnCustomization)) },
            setColumnVisible: { id, visible in
                customization.wrappedValue[visibility: id.rawValue] = visible ? .visible : .hidden
            },
            sortColumns: Self.columns.filter { $0 == .title || Self.isVisible($0, in: columnCustomization) },
            hasContainerOrder: false,
            isSortable: true,
            sortOrder: model.sortOrder,
            setSortOrder: { setSort($0) }
        )
    }

    static func isVisible(_ id: TrackColumnID, in customization: TableColumnCustomization<FolderOutlineRow>) -> Bool {
        switch customization[visibility: id.rawValue] {
        case .visible: true
        case .hidden: false
        default: id.isVisibleByDefault
        }
    }

    // MARK: Primary action (UC-PRIM-01/06/07)

    private func primary(_ ids: Set<Int64>) {
        let ordered = model.outline.order.filter(ids.contains)
        guard let first = ordered.first else { return }
        if model.folder(id: first) != nil {
            // Return / double-click on folder rows: expand or collapse (UC-PRIM-06).
            for id in ordered {
                if let folder = model.folder(id: id) { model.toggle(folder.path) }
            }
        } else if model.file(id: first) != nil {
            // A file that isn't in the library: import it (UC-PRIM-07).
            let files = ordered.compactMap { model.file(id: $0)?.path }
            Task { await model.importFiles(files) }
        } else {
            actions.primary(ids)
        }
    }

    // MARK: Keys (UC-KEY-01/05/33, DEC-053) — only while this table has focus

    /// ⌘↓ / ⌘↑ for the menu bar's Volume items, which give way to them here (DEC-053).
    private var outlineKeys: FolderOutlineKeys {
        let selected = model.outline.order.filter(model.trackList.selection.contains)
        let folder = selected.count == 1 ? model.folder(id: selected[0]) : nil
        let model = self.model
        var keys = FolderOutlineKeys()
        if let path = folder?.path {
            keys.openAsRoot = { model.openAsRoot(path) }
        }
        if !model.root.isEmpty {
            keys.goUp = { _ = model.goUp() }
        }
        return keys
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let preview = container.playbackViewModel?.preview
        if press.key == .escape {
            guard press.modifiers.isDisjoint(with: [.command, .control, .option, .shift]), let preview else { return .ignored }
            return preview.escapeKey(previewKeyPhase(press.phase)) ? .handled : .ignored
        }
        guard press.phase != .up else { return .ignored }
        // ⌘↓ open as root, ⌘↑ up (when the menu bar didn't take them first).
        if press.modifiers == .command {
            switch press.key {
            case .downArrow:
                guard let open = outlineKeys.openAsRoot else { return .ignored }
                open()
                return .handled
            case .upArrow:
                guard let up = outlineKeys.goUp else { return .ignored }
                up()
                return .handled
            default:
                return .ignored
            }
        }
        if press.key == .upArrow || press.key == .downArrow { return .ignored }
        let isPreviewing = preview?.isActive == true
        if press.key == .space || isPreviewing {
            let key: TrackListPreviewKey.Key = switch press.key {
            case .space: .space
            case .leftArrow: .leftArrow
            default: .rightArrow
            }
            let decision = TrackListPreviewKey.decide(
                key: key, isRepeat: press.phase == .repeat,
                hasCommandModifiers: !press.modifiers.isDisjoint(with: [.command, .control, .option, .shift]),
                isPreviewing: isPreviewing,
                secondsSinceTypeSelect: typeSelect.last.map { Date().timeIntervalSince($0) }
            )
            switch decision {
            case .togglePreview:
                typeSelect.last = nil
                actions.preview()
                return .handled
            case .endPreview:
                preview?.escape()
                return .handled
            case .seek(let delta):
                preview?.seek(by: delta)
                return .handled
            case .swallow:
                return .handled
            case .passOn:
                if press.key == .space { return .ignored }
            }
        }
        // → / ← expand and collapse; ⌥ for everything inside (UC-KEY-33).
        guard press.modifiers.isDisjoint(with: [.command, .control, .shift]) else { return .ignored }
        let all = press.modifiers.contains(.option)
        let selected = model.outline.order.filter(model.trackList.selection.contains)
        guard let first = selected.first else { return .ignored }
        if press.key == .rightArrow {
            guard let folder = model.folder(id: first) else { return .ignored }
            if all { model.expandAll(folder.path) } else { model.setExpanded(folder.path, true) }
            return .handled
        }
        if let folder = model.folder(id: first), folder.isExpanded || all {
            if all { model.collapseAll(folder.path) } else { model.setExpanded(folder.path, false) }
            return .handled
        }
        // ← on a closed folder, a track or a file: to the folder it lies in.
        if let parent = model.outline.parentByID[first], parent != model.root {
            model.trackList.selection = [model.ids.folder(parent)]
            model.trackList.scrollTo(model.ids.folder(parent))
            return .handled
        }
        return .ignored
    }
}

/// ⌘↓ / ⌘↑ on the focused outline (DEC-053, UC-KEY-09): published while the table has focus;
/// the Playback menu's Volume items run these instead when the key was pressed here.
struct FolderOutlineKeys {
    /// Open the selected folder as the root; nil unless exactly one folder row is selected.
    var openAsRoot: (@MainActor () -> Void)?
    /// One level up; nil at the library folder.
    var goUp: (@MainActor () -> Void)?
}

extension FocusedValues {
    /// The focused Folders outline (W3-FOLD).
    @Entry var folderOutlineKeys: FolderOutlineKeys?
}

// MARK: - Rows (recursive)

/// The outline's rows: a folder is a `DisclosureTableRow` whose content is its children —
/// expanded state is the model's (persisted per library); children are built only for open
/// folders (a closed folder carries one hidden placeholder child, so it keeps its triangle
/// without reading anything).
struct FolderOutlineRows: TableRowContent {
    typealias TableRowValue = FolderOutlineRow

    let rows: [FolderOutlineRow]
    let model: FolderViewModel
    let folderActions: FolderActions
    let dragContext: TrackDragContext

    var tableRowBody: some TableRowContent<FolderOutlineRow> {
        ForEach(rows) { row in
            if let folder = row.folder, let children = row.children {
                DisclosureTableRow(row, isExpanded: expansion(folder.path)) {
                    FolderOutlineRows(rows: children, model: model, folderActions: folderActions, dragContext: dragContext)
                }
                .draggable(folderActions.dragItem(for: folder, context: dragContext))
                .dropDestination(for: URL.self) { urls in folderActions.drop(urls, on: folder) }
            } else if let folder = row.folder {
                TableRow(row)
                    .draggable(folderActions.dragItem(for: folder, context: dragContext))
                    .dropDestination(for: URL.self) { urls in folderActions.drop(urls, on: folder) }
            } else if let track = row.track {
                // The shared track payload: ids + the reachable file (UC-DND-01/02).
                TableRow(row)
                    .draggable(dragContext.item(for: track, sourcePlaylistID: nil)
                        ?? TrackDragItem(trackId: track.id, libraryId: dragContext.libraryID))
            } else if let file = row.file {
                // Not in library: to Finder as a file only (UC-DND-06).
                TableRow(row)
                    .draggable(folderActions.fileURL(file))
            } else {
                TableRow(row)
            }
        }
    }

    private func expansion(_ path: String) -> Binding<Bool> {
        let model = self.model
        return Binding(
            get: { model.isShownExpanded(path) },
            set: { model.setExpanded(path, $0) }
        )
    }
}

// MARK: - Columns and cells

extension FolderOutlineRow {
    /// Key paths the header compares to show its sort indicator; the sorting itself is
    /// `TrackRowSorter` within each folder (`FolderOutline`).
    var nameSortKey: String { folder?.name ?? track?.title ?? file?.name ?? "" }
    var artistSortKey: String { track?.artistSortKey ?? "" }
    var albumSortKey: String { track?.albumSortKey ?? "" }
    var durationSortKey: Int { track?.durationSortKey ?? -1 }
    var bpmSortKey: Int { track?.bpmSortKey ?? -1 }
    var energySortKey: Int { track?.energySortKey ?? -1 }
    var danceSortKey: Double { track?.danceSortKey ?? -1 }
    var genreSortKey: String { track?.genreSortKey ?? "" }
    var yearSortKey: Int { track?.yearSortKey ?? -1 }
    var formatSortKey: String { track?.formatSortKey ?? "" }
    var bitrateSortKey: Int { track?.bitrateSortKey ?? -1 }
    var addedSortKey: String { track?.addedSortKey ?? "" }
    var statusSortKey: Int { track?.statusSortKey ?? -1 }
}

enum FolderTableColumns {
    @MainActor
    static func column(_ id: TrackColumnID) -> some TableColumnContent<FolderOutlineRow, KeyPathComparator<FolderOutlineRow>> {
        let width = id.width
        return base(id)
            .width(min: width.min, ideal: id == .title ? 340 : width.ideal, max: width.max)
            .alignment(id.isNumeric ? .numeric : .leading)
            .customizationID(id.rawValue)
            .defaultVisibility(id.isVisibleByDefault ? .visible : .hidden)
            .disabledCustomizationBehavior(id.isHideable ? [] : .visibility)
    }

    /// `Name` instead of `Title`: the column names folders, tracks and files (V-FOLD.E05).
    static func title(_ id: TrackColumnID) -> String { id == .title ? "Name" : id.title }

    private static func base(_ id: TrackColumnID) -> TableColumn<FolderOutlineRow, KeyPathComparator<FolderOutlineRow>, FolderCell, Text> {
        let name = title(id)
        switch id {
        case .number, .title: return TableColumn(name, value: \FolderOutlineRow.nameSortKey) { FolderCell(column: id, row: $0) }
        case .artist: return TableColumn(name, value: \FolderOutlineRow.artistSortKey) { FolderCell(column: id, row: $0) }
        case .album: return TableColumn(name, value: \FolderOutlineRow.albumSortKey) { FolderCell(column: id, row: $0) }
        case .time: return TableColumn(name, value: \FolderOutlineRow.durationSortKey) { FolderCell(column: id, row: $0) }
        case .bpm: return TableColumn(name, value: \FolderOutlineRow.bpmSortKey) { FolderCell(column: id, row: $0) }
        case .energy: return TableColumn(name, value: \FolderOutlineRow.energySortKey) { FolderCell(column: id, row: $0) }
        case .dance: return TableColumn(name, value: \FolderOutlineRow.danceSortKey) { FolderCell(column: id, row: $0) }
        case .genre: return TableColumn(name, value: \FolderOutlineRow.genreSortKey) { FolderCell(column: id, row: $0) }
        case .year: return TableColumn(name, value: \FolderOutlineRow.yearSortKey) { FolderCell(column: id, row: $0) }
        case .format: return TableColumn(name, value: \FolderOutlineRow.formatSortKey) { FolderCell(column: id, row: $0) }
        case .kbps: return TableColumn(name, value: \FolderOutlineRow.bitrateSortKey) { FolderCell(column: id, row: $0) }
        case .added: return TableColumn(name, value: \FolderOutlineRow.addedSortKey) { FolderCell(column: id, row: $0) }
        // Genre-page context columns never appear in Folders; they sort like Status if asked for.
        case .status, .match, .suggestion, .version, .location, .usedIn, .source: return TableColumn(name, value: \FolderOutlineRow.statusSortKey) { FolderCell(column: id, row: $0) }
        }
    }

    static func comparator(_ order: TrackSortOrder) -> KeyPathComparator<FolderOutlineRow> {
        let direction: SortOrder = order.ascending ? .forward : .reverse
        switch order.column {
        case .number, .title: return KeyPathComparator(\FolderOutlineRow.nameSortKey, order: direction)
        case .artist: return KeyPathComparator(\FolderOutlineRow.artistSortKey, order: direction)
        case .album: return KeyPathComparator(\FolderOutlineRow.albumSortKey, order: direction)
        case .time: return KeyPathComparator(\FolderOutlineRow.durationSortKey, order: direction)
        case .bpm: return KeyPathComparator(\FolderOutlineRow.bpmSortKey, order: direction)
        case .energy: return KeyPathComparator(\FolderOutlineRow.energySortKey, order: direction)
        case .dance: return KeyPathComparator(\FolderOutlineRow.danceSortKey, order: direction)
        case .genre: return KeyPathComparator(\FolderOutlineRow.genreSortKey, order: direction)
        case .year: return KeyPathComparator(\FolderOutlineRow.yearSortKey, order: direction)
        case .format: return KeyPathComparator(\FolderOutlineRow.formatSortKey, order: direction)
        case .kbps: return KeyPathComparator(\FolderOutlineRow.bitrateSortKey, order: direction)
        case .added: return KeyPathComparator(\FolderOutlineRow.addedSortKey, order: direction)
        case .status, .match, .suggestion, .version, .location, .usedIn, .source: return KeyPathComparator(\FolderOutlineRow.statusSortKey, order: direction)
        }
    }

    /// The order a header click asked for.
    static func order(_ comparator: KeyPathComparator<FolderOutlineRow>) -> TrackSortOrder? {
        guard let column = FolderOutlineTable.columns.first(where: { keyPath($0) == comparator.keyPath }) else { return nil }
        return TrackSortOrder(column: column, ascending: comparator.order == .forward)
    }

    static func keyPath(_ id: TrackColumnID) -> PartialKeyPath<FolderOutlineRow> {
        switch id {
        case .number, .title: \FolderOutlineRow.nameSortKey
        case .artist: \FolderOutlineRow.artistSortKey
        case .album: \FolderOutlineRow.albumSortKey
        case .time: \FolderOutlineRow.durationSortKey
        case .bpm: \FolderOutlineRow.bpmSortKey
        case .energy: \FolderOutlineRow.energySortKey
        case .dance: \FolderOutlineRow.danceSortKey
        case .genre: \FolderOutlineRow.genreSortKey
        case .year: \FolderOutlineRow.yearSortKey
        case .format: \FolderOutlineRow.formatSortKey
        case .kbps: \FolderOutlineRow.bitrateSortKey
        case .added: \FolderOutlineRow.addedSortKey
        case .status, .match, .suggestion, .version, .location, .usedIn, .source: \FolderOutlineRow.statusSortKey
        }
    }
}

/// One cell: a track row is drawn by the shared `TrackCell` (the All Tracks cells); a folder
/// row names the folder and its contents; a file row is dimmed with `Not in library`.
struct FolderCell: View {
    let column: TrackColumnID
    let row: FolderOutlineRow

    var body: some View {
        switch row.kind {
        case .track(let track):
            TrackCell(column: column, row: track)
        case .folder(let info):
            FolderRowCell(column: column, info: info)
        case .file(let info):
            FolderFileCell(column: column, info: info)
        case .loading:
            if column == .title {
                Text("Loading…")
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Folder row: symbol, name (`Managed by MLM` after it on app-owned folders) and `48 tracks`;
/// Status: `Scanning…`, `Can’t read this folder` or `‹n› not in library` (UC-TABLE-12).
private struct FolderRowCell: View {
    let column: TrackColumnID
    let info: FolderRowInfo

    var body: some View {
        switch column {
        case .title:
            HStack(spacing: Spacing.s) {
                Image(systemName: info.isManaged ? "arrow.down.circle" : "folder")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(info.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(FolderRowText.facts(info))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .typeSelectEquivalent(info.name)
            .help(info.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(FolderRowText.accessibility(info))
        case .status:
            if info.isScanning {
                Label {
                    Text("Scanning…").foregroundStyle(.secondary)
                } icon: {
                    ProgressView().controlSize(.mini)
                }
            } else if let reason = info.unreadableReason {
                Label {
                    Text(FolderRowText.unreadable).foregroundStyle(.secondary).lineLimit(1)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .help("MLM couldn’t read this folder — \(reason).")
            } else if let count = info.notInLibraryCount, count > 0 {
                Text(FolderRowText.notInLibrary(count))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        default:
            EmptyView()
        }
    }
}

/// A file that isn't in the library: dimmed (UC-TABLE-10), `—` for values, Status `Not in library`.
private struct FolderFileCell: View {
    let column: TrackColumnID
    let info: FolderFileInfo

    var body: some View {
        switch column {
        case .title:
            HStack(spacing: Spacing.s) {
                Image(systemName: "doc")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(info.name)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .typeSelectEquivalent(info.name)
            .help(info.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(info.name), \(TrackStatusDisplay.notInLibrary.text)")
        case .status:
            Label {
                Text(TrackStatusDisplay.notInLibrary.text).foregroundStyle(.tertiary).lineLimit(1)
            } icon: {
                Image(systemName: TrackStatusDisplay.notInLibrary.systemImage).foregroundStyle(.tertiary)
            }
        default:
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// The words of a folder row (§15.9, UC-TABLE-12).
enum FolderRowText {
    /// `48 tracks` · `Managed by MLM`.
    static func facts(_ info: FolderRowInfo) -> String {
        var parts = [StatusBarText.tracks(info.trackCount)]
        if info.isManaged { parts.append(managed) }
        return parts.joined(separator: " · ")
    }

    static let managed = "Managed by MLM"
    static let unreadable = "Can’t read this folder"

    /// `14 not in library`
    static func notInLibrary(_ count: Int) -> String { "\(count.formatted(.number)) not in library" }

    static func accessibility(_ info: FolderRowInfo) -> String {
        var parts = ["Folder", info.name, facts(info)]
        if info.isScanning { parts.append("Scanning…") }
        if info.unreadableReason != nil { parts.append(unreadable) }
        if let count = info.notInLibraryCount, count > 0 { parts.append(notInLibrary(count)) }
        return parts.joined(separator: ", ")
    }
}
