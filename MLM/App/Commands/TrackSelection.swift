import SwiftUI

// MARK: - Track selection contract (UC-SEL-02, DEC-038)

/// The container a focused track list shows; decides `Remove from ‹Container›` (UC-KEY-17,
/// UC-CM-08) and whether `Remove from Library…` exists (UC-CM-07).
enum TrackListContainer: Equatable, Sendable {
    /// All Tracks: nothing to remove from — ⌫ does nothing there (UC-KEY-17).
    case library
    case playlist(id: Int64, name: String)
    case queue
    case syncProfile(id: Int64, name: String)
    /// Search results, sheet tables and other lists without a container.
    case none
}

/// What the focused list is, for the commands that act on it as a whole.
struct TrackListContext: Equatable, Sendable {
    var container: TrackListContainer
    /// The list's name in `Play ‹name›` / `Shuffle ‹name›` (`All Tracks`, `“Warm-up”`); `nil`
    /// when the list has no view-wide Play / Shuffle (search results, the queue).
    var viewName: String?
    /// The kept-alive All Tracks table, which may only act while All Tracks is the visible place.
    var isAllTracksTable = false

    static let allTracks = TrackListContext(container: .library, viewName: "All Tracks", isAllTracksTable: true)
    static let unnamed = TrackListContext(container: .none, viewName: nil)
    /// The Queue column's tables: no Remove from Library (UC-CM-07); Remove from Queue arrives
    /// with W2-D's queue target.
    static let queue = TrackListContext(container: .queue, viewName: nil)

    static func playlist(id: Int64, name: String) -> TrackListContext {
        TrackListContext(container: .playlist(id: id, name: name), viewName: "“\(name)”")
    }
}

/// The list-specific half of the track commands — what only the focused list can do. The
/// commands every list shares (Play Next, Download, Show in Finder, Copy, Add to Playlist,
/// Remove from Library…, Get Info, New Playlist from Selection) are implemented once in
/// `TrackCommandActions` and act on `TrackSelection.selectedTracks`.
struct TrackCommandTarget {
    /// The list's primary action on a track, with the visible rows as queue context (the same
    /// closure as double-click / Return). `nil`: the list can't play.
    var activate: ((Track, [Track]) -> Void)?
    /// Remove the selected IDs from the list's container (undoable from W2-F on).
    var removeFromContainer: ((Set<Int64>) -> Void)?
    /// Clear the list's selection (Edit ▸ Deselect All).
    var deselectAll: (() -> Void)?
    /// Playlists offered in Add to Playlist ▸ (the current playlist is left out, UC-CM-08).
    var playlists: [Playlist] = []
    /// Sync profiles offered in Add to Sync Profile ▸ and how to add to one.
    var syncProfiles: [SyncProfile] = []
    var addToSyncProfile: ((SyncProfile, Set<Int64>) -> Void)?
    /// Track ▸ Preview: the list's Space (start / end the preview of its selection, W2-C).
    /// `nil`: the list can't preview.
    var preview: (() -> Void)?
    /// Records the list as the playing context before a menu command plays from it (⌘L, W2-C).
    var recordOrigin: (() -> Void)?
}

/// The focused track list as the menu bar sees it — cheap to publish and to compare.
///
/// It carries the selected IDs, a `TrackSelectionSummary` computed **once** by the publisher
/// from the selected rows only, whether the list has a playable row, the list's context and its
/// `TrackCommandTarget`. Full `Track` rows are produced only inside an action (`rows`,
/// `selectedTracks`), never to decide what is enabled — a 12,000-row table costs one pass over
/// row IDs per publish, not 12,000 `Track` copies per command.
///
/// Equality ignores the closures and compares IDs, summary, context and `rowsToken` (which
/// changes when the rows or their order change), so an unchanged selection doesn't re-run the
/// menus, and a changed list never leaves an action holding stale rows.
///
/// **Publishing (any track list):**
/// ```swift
/// Table(selection: $selection) { … }
///     .focusedValue(\.trackSelection, TrackSelection(
///         selectedIDs: selection, rows: rowsInDisplayOrder,
///         id: \.id, isPlayable: { $0.track.isLocal }, track: \.track,
///         context: .playlist(id: id, name: name),
///         target: TrackCommandTarget(activate: onDoubleClick, removeFromContainer: remove, …)))
/// ```
/// `.focusedValue` (not the scene variant): the Track menu follows keyboard focus, so it acts
/// on the list the user is in (UC-SEL-02) and is disabled in Settings, the Activity window and
/// sheets (UC-MENU-04). W2-A's track table publishes this from its single component.
struct TrackSelection: Equatable {
    let selectedIDs: Set<Int64>
    /// The selection's counts, in display order (first selected track first).
    let summary: TrackSelectionSummary
    let context: TrackListContext
    /// The list has a row that can play (Playback ▸ Play / Shuffle ‹view›).
    let hasPlayableRows: Bool
    /// Changes whenever the rows or their order change.
    let rowsToken: Int
    let target: TrackCommandTarget
    private let loadRows: () -> [Track]

    /// Builds the value from the list's rows in display order without copying a `Track` that
    /// isn't selected.
    init<Rows: RandomAccessCollection>(
        selectedIDs: Set<Int64>,
        rows: Rows,
        id: @escaping (Rows.Element) -> Int64,
        isPlayable: (Rows.Element) -> Bool,
        track: @escaping (Rows.Element) -> Track,
        context: TrackListContext,
        target: TrackCommandTarget
    ) {
        var hasher = Hasher()
        hasher.combine(rows.count)
        var selected: [Track] = []
        for row in rows {
            let rowID = id(row)
            hasher.combine(rowID)
            if !selectedIDs.isEmpty, selectedIDs.contains(rowID) { selected.append(track(row)) }
        }
        self.selectedIDs = selectedIDs
        self.summary = TrackSelectionSummary(tracks: selected, container: context.container)
        self.context = context
        self.hasPlayableRows = rows.contains(where: isPlayable)
        self.rowsToken = hasher.finalize()
        self.target = target
        self.loadRows = { rows.map(track) }
    }

    /// Plain tracks (tests, small lists).
    init(selectedIDs: Set<Int64>, rows: [Track], context: TrackListContext, target: TrackCommandTarget) {
        self.init(selectedIDs: selectedIDs, rows: rows, id: { $0.id ?? -1 }, isPlayable: \.isLocal,
                  track: { $0 }, context: context, target: target)
    }

    /// From precomputed parts — the track table (`TrackListTable`) publishes this way: the
    /// summary comes from the selected rows only and `rowsToken` / `hasPlayableRows` were
    /// computed once per load, so a selection change or an arrow step costs O(selection).
    init(
        selectedIDs: Set<Int64>,
        summary: TrackSelectionSummary,
        context: TrackListContext,
        hasPlayableRows: Bool,
        rowsToken: Int,
        target: TrackCommandTarget,
        rows: @escaping () -> [Track]
    ) {
        self.selectedIDs = selectedIDs
        self.summary = summary
        self.context = context
        self.hasPlayableRows = hasPlayableRows
        self.rowsToken = rowsToken
        self.target = target
        self.loadRows = rows
    }

    static func == (lhs: TrackSelection, rhs: TrackSelection) -> Bool {
        lhs.selectedIDs == rhs.selectedIDs && lhs.summary == rhs.summary && lhs.context == rhs.context
            && lhs.hasPlayableRows == rhs.hasPlayableRows && lhs.rowsToken == rhs.rowsToken
    }

    /// Every row of the list in display order — for actions only.
    var rows: [Track] { loadRows() }

    /// Selected tracks in display order — for actions only.
    var selectedTracks: [Track] {
        guard !selectedIDs.isEmpty else { return [] }
        return rows.filter { track in track.id.map(selectedIDs.contains) ?? false }
    }

    /// The selection the menu may act on: the kept-alive All Tracks table keeps keyboard focus
    /// while another place shows, so its selection only counts while All Tracks is visible.
    func usable(allTracksVisible: Bool) -> TrackSelection? {
        context.isAllTracksTable && !allTracksVisible ? nil : self
    }
}

extension TrackSelection {
    /// `selection` if the menu may act on it now (see `usable(allTracksVisible:)`): All Tracks
    /// is visible when it is the selected place, nothing is pushed over it and the search pane
    /// isn't covering it.
    @MainActor
    static func usable(_ selection: TrackSelection?, navigation: NavigationModel?) -> TrackSelection? {
        let allTracksVisible = (navigation?.isAllTracksVisible ?? false)
            && !DependencyContainer.shared.searchCoordinator.isPresented
        return selection?.usable(allTracksVisible: allTracksVisible)
    }
}

extension FocusedValues {
    /// The focused track list (Track menu, Edit ▸ Deselect All, File ▸ New Playlist from
    /// Selection, Playback ▸ Play / Shuffle ‹view›). Published with `.focusedValue`.
    @Entry var trackSelection: TrackSelection?
}

// MARK: - Pure enabling logic

/// Counts that decide which track commands apply, computed without touching the disk
/// (UC-TABLE-20: availability of a track without a file comes from its stored state).
struct TrackSelectionSummary: Equatable, Sendable {
    var count = 0
    /// Tracks whose file can be used now: Local, and not on a disk that is away. Play, Play
    /// Next, Show in Finder and Copy ▸ File Path need one (UC-CM-05).
    var localCount = 0
    var notDownloadedCount = 0
    var failedCount = 0
    /// `File missing` (persisted; never because of the drive).
    var missingCount = 0
    /// Local / file-missing tracks on the library's disk while it is not connected.
    var unreachableCount = 0
    var firstIsLocal = false
    /// The first selected track in display order (Get Info).
    var firstID: Int64?
    var container: TrackListContainer = .none

    init(count: Int = 0, localCount: Int = 0, notDownloadedCount: Int = 0, failedCount: Int = 0,
         firstIsLocal: Bool = false, container: TrackListContainer = .none) {
        self.count = count
        self.localCount = localCount
        self.notDownloadedCount = notDownloadedCount
        self.failedCount = failedCount
        self.firstIsLocal = firstIsLocal
        self.container = container
    }

    /// From tracks alone (persisted availability; no drive context).
    init(tracks: [Track], container: TrackListContainer) {
        self.count = tracks.count
        self.firstID = tracks.first?.id
        self.container = container
        for (index, track) in tracks.enumerated() {
            add(track.availability(), unreachable: false, isFirst: index == 0)
        }
    }

    /// From a track table's selected rows in display order, with the window's drive state.
    init(rows: [TrackRow], container: TrackListContainer, live: TrackTableLiveState) {
        self.count = rows.count
        self.firstID = rows.first?.id
        self.container = container
        for (index, row) in rows.enumerated() {
            let unreachable = TrackRowPresentation.isUnreachable(
                availability: row.availability, fileLocation: row.fileLocation, live: live)
            add(row.availability, unreachable: unreachable, isFirst: index == 0)
        }
    }

    private mutating func add(_ availability: TrackAvailability, unreachable: Bool, isFirst: Bool) {
        if unreachable {
            unreachableCount += 1
            return
        }
        switch availability {
        case .local:
            localCount += 1
            if isFirst { firstIsLocal = true }
        case .fileMissing: missingCount += 1
        case .failed: failedCount += 1
        case .downloading: break
        case .notDownloaded: notDownloadedCount += 1
        }
    }

    /// Tracks a Download would fetch (not downloaded or failed).
    var downloadableCount: Int { notDownloadedCount + failedCount }
}

/// What the focused list supports, from its `TrackCommandTarget`.
struct TrackListCapabilities: Equatable, Sendable {
    var canActivate = false
    var canRemoveFromContainer = false
    var canDeselect = false
    var canAddToSyncProfile = false

    init(canActivate: Bool = false, canRemoveFromContainer: Bool = false, canDeselect: Bool = false,
         canAddToSyncProfile: Bool = false) {
        self.canActivate = canActivate
        self.canRemoveFromContainer = canRemoveFromContainer
        self.canDeselect = canDeselect
        self.canAddToSyncProfile = canAddToSyncProfile
    }

    init(_ target: TrackCommandTarget) {
        self.init(
            canActivate: target.activate != nil,
            canRemoveFromContainer: target.removeFromContainer != nil,
            canDeselect: target.deselectAll != nil,
            canAddToSyncProfile: target.addToSyncProfile != nil
        )
    }
}

/// Which track commands are enabled and how they are titled for a selection — pure, so the
/// rules are unit-tested (`TrackCommandStateTests`).
struct TrackCommandState: Equatable, Sendable {
    var canPlay = false
    var canPlayNext = false
    var canAddTo = false
    var canAddToSyncProfile = false
    var canGetInfo = false
    var canDownload = false
    var canShowInFinder = false
    var canCopy = false
    var canCopyFilePath = false
    var canRemoveFromContainer = false
    var canRemoveFromLibrary = false
    var canDeselectAll = false
    var downloadTitle = MenuCommand.download.title
    var removeFromContainerTitle = MenuCommand.removeFromContainer.title
    /// Help text of a disabled Download.
    var downloadDisabledReason: String?

    static let downloadBusyReason = "Another download is running. Try again when it has finished."

    /// - Parameters:
    ///   - summary: the usable selection, or `nil` when no track list has focus.
    ///   - isDownloadBusy: a download batch is running (a second one is rejected today).
    init(summary: TrackSelectionSummary?, capabilities: TrackListCapabilities, isDownloadBusy: Bool) {
        guard let summary, summary.count > 0 else { return }
        let inContainer: Bool
        switch summary.container {
        case .playlist, .queue, .syncProfile: inContainer = true
        case .library, .none: inContainer = false
        }

        canPlay = capabilities.canActivate && summary.firstIsLocal
        canPlayNext = summary.localCount > 0
        canAddTo = true
        canAddToSyncProfile = capabilities.canAddToSyncProfile
        canGetInfo = true
        canShowInFinder = summary.localCount > 0
        canCopy = true
        canCopyFilePath = summary.localCount > 0
        canRemoveFromContainer = inContainer && capabilities.canRemoveFromContainer
        // Remove from Library does not exist in the queue or a sync profile (UC-CM-07).
        switch summary.container {
        case .queue, .syncProfile: canRemoveFromLibrary = false
        default: canRemoveFromLibrary = true
        }
        canDeselectAll = capabilities.canDeselect

        downloadTitle = Self.downloadTitle(summary)
        if summary.downloadableCount == 0 {
            canDownload = false
        } else if isDownloadBusy {
            canDownload = false
            downloadDisabledReason = Self.downloadBusyReason
        } else {
            canDownload = true
        }
        removeFromContainerTitle = Self.removeTitle(summary.container)
    }

    /// `Download` · `Retry Download` · `Download 3 Tracks` (UC-MENU-03, M-TRACK.N10).
    static func downloadTitle(_ summary: TrackSelectionSummary) -> String {
        let count = summary.downloadableCount
        if count > 1 { return "Download \(count.formatted(.number)) Tracks" }
        if count == 1, summary.failedCount == 1 { return "Retry Download" }
        return MenuCommand.download.title
    }

    /// Help text of a disabled `Remove from ‹Container›` (UC-COPY-13), short and user-facing.
    static func removeDisabledReason(_ container: TrackListContainer) -> String {
        switch container {
        case .library: "All Tracks has nothing to remove tracks from. Remove from Library… deletes them."
        case .queue: "Removing tracks from the queue isn’t available yet."
        case .playlist, .syncProfile: "These tracks can’t be removed here yet."
        case .none: "This list has nothing to remove tracks from."
        }
    }

    /// `Remove from “Warm-up”` · `Remove from Queue` · `Remove from “iPod Classic”`
    /// (UC-MENU-03, UC-CM-08); the base title where there is no container.
    static func removeTitle(_ container: TrackListContainer) -> String {
        switch container {
        case .playlist(_, let name), .syncProfile(_, let name): "Remove from “\(name)”"
        case .queue: "Remove from Queue"
        case .library, .none: MenuCommand.removeFromContainer.title
        }
    }
}
