import Foundation

// MARK: - Selection bar: the pure model (P-SELBAR, UC-SELBAR-01…05, DEC-015)

/// Which scaffold a selection bar sits in. The search pane is drawn over the place it searches,
/// so while searching only its bar may show; a place's bar shows only while nothing covers it.
enum TrackSelectionBarHost: Equatable, Sendable {
    /// A sidebar destination or pushed detail (All Tracks, a playlist, later albums, genres…).
    case place
    /// The search results pane.
    case searchResults
}

/// When a track list may drive the selection bar of its scaffold — pure, so the rule that a
/// hidden table never drives it is unit-tested.
enum TrackSelectionBarVisibility {
    /// - Parameters:
    ///   - host: the scaffold the bar sits in.
    ///   - list: the list the selection belongs to.
    ///   - allTracksVisible: All Tracks is the selected place and nothing is pushed over it.
    ///   - isSearching: the search pane covers the places.
    static func isShown(
        host: TrackSelectionBarHost,
        list: TrackListContext,
        allTracksVisible: Bool,
        isSearching: Bool
    ) -> Bool {
        // Not in the Queue column (UC-SELBAR-05); grids, the sidebar and sheets host no track
        // table that registers with a bar.
        if list.container == .queue { return false }
        switch host {
        case .searchResults:
            return isSearching
        case .place:
            // The kept-alive All Tracks table only while All Tracks shows (as for the menus).
            return !isSearching && TrackTableVisibility.isVisible(
                isAllTracksTable: list.isAllTracksTable,
                allTracksVisible: allTracksVisible,
                isSearching: isSearching
            )
        }
    }
}

/// One button (or menu button) of the bar.
struct SelectionBarAction: Equatable, Sendable {
    enum ID: Equatable, Sendable {
        case playNext, addToPlaylist, editInfo, download, more
    }

    let id: ID
    /// Title Case label (UC-COPY-02); also the accessibility label when only the icon shows.
    let title: String
    /// Shown instead of the title when the bar is narrow.
    let systemImage: String
    let isEnabled: Bool
    /// Tooltip: the reason while disabled (UC-COPY-13), else the title with its menu-bar key
    /// (UC-A11Y-02) — the bar itself registers no key (UC-KEY-36).
    let help: String
}

/// What the selection bar shows for a selection: the count and duration, the four actions in
/// UC-SELBAR-02 order and the `More` menu. `nil` from `make` = no bar.
///
/// - `Play Next` · `Add to Playlist ▾` · `Edit Info` are always present; an action that can't
///   run is **disabled** with its reason (it is a bar, not a context menu).
/// - `Download` is present **only** while the selection has Not downloaded / Download failed
///   tracks (UC-SELBAR-02); disabled while another download batch runs.
/// - `More` (•••) is the multi-selection track menu (`TrackMenuModel`, the same builder as the
///   context menu, UC-CM-02) minus the bar's own four actions.
struct SelectionBarState: Equatable, Sendable {
    /// Fewer selected rows than this: no bar (UC-SELBAR-01).
    static let minimumCount = 2

    let count: Int
    /// `14 selected` (thousands separators).
    let countText: String
    /// `52 min` · `2 h 51 min` · `38 days`.
    let durationText: String
    /// VoiceOver label of the bar and its one announcement when it appears:
    /// `Selection actions, 14 tracks selected`.
    let accessibilityLabel: String
    let playNext: SelectionBarAction
    let addToPlaylist: SelectionBarAction
    let editInfo: SelectionBarAction
    /// `nil` = hidden: nothing in the selection needs downloading.
    let download: SelectionBarAction?
    let more: SelectionBarAction
    /// The `More` menu's items, in DEC-039 group order.
    let moreMenu: TrackMenuModel

    /// The bar's controls, left to right (UC-SELBAR-02).
    var actions: [SelectionBarAction] {
        [playNext, addToPlaylist, editInfo] + (download.map { [$0] } ?? []) + [more]
    }

    /// - Parameters:
    ///   - rows: the **shown** selected rows in display order (`TrackListModel.selectedRows()`).
    ///   - context: what the list supports (the same context its context menu uses).
    ///   - live: the window's drive state (and running downloads) as the table sees it.
    ///   - isDownloadBusy: a download batch is running (a second one is refused today).
    ///   - canShowInfo: the window has the Info column.
    @MainActor
    static func make(
        rows: [TrackRow],
        context: TrackMenuContext,
        live: TrackTableLiveState,
        isDownloadBusy: Bool,
        canShowInfo: Bool
    ) -> SelectionBarState? {
        guard rows.count >= minimumCount, context.container != .queue else { return nil }
        let summary = TrackSelectionSummary(rows: rows, container: context.container, live: live)
        let seconds = rows.reduce(0) { $0 + max($1.track.duration ?? 0, 0) }

        let playNextReason: String?
        if summary.localCount > 0 {
            playNextReason = nil
        } else if summary.unreachableCount > 0, let volume = live.offlineVolumeName {
            playNextReason = TrackMenu.notConnectedHelp(volume)
        } else {
            playNextReason = noPlayableReason
        }

        var download: SelectionBarAction?
        if summary.downloadableCount > 0 {
            download = SelectionBarAction(
                id: .download, title: "Download", systemImage: "arrow.down.circle",
                isEnabled: !isDownloadBusy,
                help: isDownloadBusy
                    ? TrackCommandState.downloadBusyReason
                    : "\(TrackCommandState.downloadTitle(summary)) ⌘D"
            )
        }

        let menu = TrackMenuModel.make(subject: TrackMenuSubject(rows: rows, live: live), context: context)
        return SelectionBarState(
            count: rows.count,
            countText: "\(rows.count.formatted(.number)) selected",
            durationText: TrackDurationText.total(seconds),
            accessibilityLabel: "Selection actions, \(StatusBarText.tracks(rows.count)) selected",
            playNext: SelectionBarAction(
                id: .playNext, title: "Play Next", systemImage: "text.line.first.and.arrowtriangle.forward",
                isEnabled: playNextReason == nil, help: playNextReason ?? "Play Next ⌥↩"
            ),
            addToPlaylist: SelectionBarAction(
                id: .addToPlaylist, title: "Add to Playlist", systemImage: "text.badge.plus",
                isEnabled: true, help: "Add to Playlist"
            ),
            editInfo: SelectionBarAction(
                id: .editInfo, title: "Edit Info", systemImage: "info.circle",
                isEnabled: canShowInfo, help: canShowInfo ? "Edit Info ⌘I" : noInfoReason
            ),
            download: download,
            more: SelectionBarAction(
                id: .more, title: "More", systemImage: "ellipsis", isEnabled: true, help: "More"
            ),
            moreMenu: menu.removingSelectionBarActions()
        )
    }

    /// Play Next with nothing that has a usable file (no drive involved).
    static let noPlayableReason = "None of the selected tracks has a file that can play."
    static let noInfoReason = "Info isn’t available in this window."

    /// Playlists offered by the bar's `Add to Playlist ▾`: the current playlist is left out
    /// (UC-CM-08), as in the context menu.
    static func playlists(_ playlists: [Playlist], for container: TrackListContainer) -> [Playlist] {
        guard case .playlist(let id, _) = container else { return playlists }
        return playlists.filter { $0.id != id }
    }
}

// MARK: - More (•••)

extension TrackMenuItem {
    /// Shown as the bar's own buttons, so left out of its `More` (UC-SELBAR-02).
    var isSelectionBarAction: Bool {
        switch self {
        case .playNext, .addToPlaylist, .getInfo, .download: true
        default: false
        }
    }
}

extension TrackMenuModel {
    /// The bar's `More`: this menu without the bar's four actions; emptied groups disappear
    /// (UC-CM-01: a subset, never a reordering).
    func removingSelectionBarActions() -> TrackMenuModel {
        TrackMenuModel(sections: sections
            .map { $0.filter { !$0.isSelectionBarAction } }
            .filter { !$0.isEmpty })
    }
}
