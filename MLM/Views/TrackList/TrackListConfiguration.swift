import SwiftUI

/// How one track table behaves in its context — the only thing a host writes besides feeding
/// rows into a `TrackListModel`.
///
/// **Hosting the table for a new context** (album, folder, genre, Similar, sheet preview):
/// ```swift
/// @State private var list = TrackListModel(sortOrder: TrackSortOrder(column: .title, ascending: true))
/// TrackListTable(model: list, configuration: TrackListConfiguration(
///     listContext: TrackListContext(container: .none, viewName: "“Techno”"),
///     persistenceKey: "genre",
///     activate: onTrackActivated
/// )) { ContentUnavailableView(…) }
/// .task { await list.setTracks(tracks) }
/// ```
/// - **Columns:** `columns` lists the columns that exist (`#` only for containers with an own
///   order); visibility of the hideable ones is the user's (`TableColumnCustomization`,
///   persisted per `persistenceKey`). A new column = a `TrackColumnID` case + its cell in
///   `TrackCell` + its sort key in `TrackRowSorter`.
/// - **Scope filter (W2-B):** filter what you hand to `setTracks` (e.g.
///   `TrackRepository.fetchTracks(scope:search:)`); the selection survives (UC-TABLE-08).
///   `showsFailureDetail` turns on the second line of failed rows for the `Download failed`
///   scope (UC-TABLE-13).
/// - **Reorder / drops (W3-PL, W2-H):** `onInsert` receives the insertion index in display
///   rows plus the providers; `dragSourcePlaylistID` tags dragged rows.
/// - **Selection:** `model.selection`; the table publishes `FocusedValues.trackSelection`,
///   `trackTableViewOptions` and `InspectedTrackSelection.shared` itself.
struct TrackListConfiguration {
    /// What the list is for the menu bar (`TrackSelection`): container, Play/Shuffle name.
    var listContext: TrackListContext
    /// Key of the persisted column customization and sort (`@SceneStorage`).
    var persistenceKey: String
    /// Columns that exist in this context, in table order.
    var columns: [TrackColumnID] = TrackColumnID.allCases.filter { $0 != .number }
    /// The container has its own order: `#` column, `Playlist Order` in Sort By, the
    /// "reordering is off" hint while sorted otherwise (UC-TABLE-05).
    var hasContainerOrder = false
    /// Sort used until the user picks one.
    var defaultSort: TrackSortOrder? = TrackSortOrder(column: .added, ascending: false)
    /// Headers can be clicked to sort (album detail: fixed order, UC-TABLE-04).
    var isSortable = true
    /// The second line `‹reason› · ‹n› attempts left` under failed rows (UC-TABLE-13): only
    /// in the `Download failed` scope (W2-B sets it).
    var showsFailureDetail = false
    /// Default status-bar text (`‹n› tracks · ‹duration›`) and the selection text
    /// (UC-STATUS-02/03). Off where the list has no status bar (the Queue column).
    var publishesStatusText = true
    /// Counts from SQL aggregates for the status bar (UC-TABLE-21); `nil` = the loaded rows.
    var totals: TrackListTotals?
    var accessibilityID = "track_table"

    // MARK: Behaviour

    /// Play `track` with `queue` as context — the host's playback path. Only called for rows
    /// that can play (`TrackPrimaryAction.play`); the table handles the other row kinds.
    var activate: ((Track, [Track]) -> Void)?
    /// ⌫ / Remove from ‹Container› (UC-KEY-17). `nil`: nothing to remove from (All Tracks).
    var removeFromContainer: ((Set<Int64>) -> Void)?
    /// The playlist rows are dragged from (reorder-aware drop targets).
    var dragSourcePlaylistID: Int64?
    /// Drops/reorder into the list at a display index (W3-PL / W2-H seam).
    var onInsert: ((Int, [NSItemProvider], [TrackRow]) -> Void)?
    /// `Album` values link to the album (UC-TABLE-18). Seam: `nil` until W4-2's album pages.
    var openAlbum: ((TrackRow) -> Void)?
}

/// Totals of the whole view (not only the loaded rows).
struct TrackListTotals: Equatable, Sendable {
    var count: Int
    /// Seconds.
    var duration: Int
}

// MARK: - Contexts

extension TrackListConfiguration {
    /// All Tracks (library): no container, Added = added to the library.
    static func allTracks(activate: ((Track, [Track]) -> Void)?, totals: TrackListTotals?) -> TrackListConfiguration {
        TrackListConfiguration(
            listContext: .allTracks,
            persistenceKey: "allTracks",
            totals: totals,
            accessibilityID: "library_table",
            activate: activate
        )
    }

    /// A playlist: `#` column, own order, ⌫ removes from it, Added = added to the playlist.
    static func playlist(
        id: Int64,
        name: String,
        activate: ((Track, [Track]) -> Void)?,
        remove: @escaping (Set<Int64>) -> Void,
        onInsert: ((Int, [NSItemProvider], [TrackRow]) -> Void)?
    ) -> TrackListConfiguration {
        TrackListConfiguration(
            listContext: .playlist(id: id, name: name),
            persistenceKey: "playlist",
            columns: TrackColumnID.allCases,
            hasContainerOrder: true,
            defaultSort: TrackSortOrder(column: .number, ascending: true),
            accessibilityID: "playlist_track_table",
            activate: activate,
            removeFromContainer: remove,
            dragSourcePlaylistID: id,
            onInsert: onInsert
        )
    }

    /// Search results: no container; ordered by relevance until sorted.
    static func searchResults(activate: ((Track, [Track]) -> Void)?) -> TrackListConfiguration {
        TrackListConfiguration(
            listContext: .unnamed,
            persistenceKey: "searchResults",
            defaultSort: nil,
            accessibilityID: "search_results_table",
            activate: activate
        )
    }

    /// A section of the Queue column: narrow, own order, no status bar.
    static func queue(section: String, accessibilityID: String, activate: ((Track, [Track]) -> Void)?) -> TrackListConfiguration {
        TrackListConfiguration(
            listContext: .queue,
            persistenceKey: "queue.\(section)",
            columns: [.title, .artist, .time, .status],
            hasContainerOrder: false,
            defaultSort: nil,
            isSortable: false,
            publishesStatusText: false,
            accessibilityID: accessibilityID,
            activate: activate
        )
    }
}

// MARK: - Focused values and seams

/// The focused table's columns and sort for View ▸ Columns / View ▸ Sort By (UC-TABLE-03/04,
/// M-VIEW.N04/N05).
struct TrackTableViewOptions {
    /// Hideable columns of this table, in menu order, with their visibility.
    var columns: [(id: TrackColumnID, isVisible: Bool)]
    var setColumnVisible: (TrackColumnID, Bool) -> Void
    /// Columns offered in Sort By (visible ones; `#` is `Playlist Order`).
    var sortColumns: [TrackColumnID]
    var hasContainerOrder: Bool
    var isSortable: Bool
    var sortOrder: TrackSortOrder?
    var setSortOrder: (TrackSortOrder?) -> Void
}

extension FocusedValues {
    /// The focused track table's column and sort controls (View menu).
    @Entry var trackTableViewOptions: TrackTableViewOptions?
}

/// The selection Info follows (W2-E seam, UC-SEL-03): the last track table the user selected
/// in writes its selected ids here, in display order. Kept as a scene-independent observable
/// so Info keeps showing the selection while focus moves into Info's fields.
@MainActor
@Observable
final class InspectedTrackSelection {
    static let shared = InspectedTrackSelection()

    /// Selected track ids in display order (first = the one Info shows for a single selection).
    private(set) var trackIDs: [Int64] = []
    /// `persistenceKey` of the table that wrote them.
    private(set) var sourceKey: String?

    func update(_ ids: [Int64], from key: String) {
        guard ids != trackIDs || key != sourceKey else { return }
        trackIDs = ids
        sourceKey = key
    }
}

/// Playlists and sync profiles offered by Add to Playlist ▸ / Add to Sync Profile ▸ — loaded
/// once for every track table and refreshed when they change.
@MainActor
@Observable
final class TrackMenuSources {
    static let shared = TrackMenuSources()

    private(set) var playlists: [Playlist] = []
    private(set) var syncProfiles: [SyncProfile] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var loaded = false

    func loadIfNeeded(container: DependencyContainer = .shared) {
        guard !loaded else { return }
        loaded = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .playlistDidChange, object: nil, queue: .main) { note in
            if let info = note.userInfo, info["coverRevalidation"] != nil || (info["origin"] as? String) == "coverService" { return }
            MainActor.assumeIsolated { TrackMenuSources.shared.reload() }
        })
        observers.append(center.addObserver(forName: .syncProfileDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TrackMenuSources.shared.reload() }
        })
        reload(container: container)
    }

    func reload(container: DependencyContainer = .shared) {
        Task {
            if let repository = container.playlistRepository {
                playlists = (try? await repository.fetchAll()) ?? playlists
            }
            if let sync = container.syncViewModel {
                if sync.profiles.isEmpty { await sync.loadProfiles() }
                syncProfiles = sync.profiles
            }
        }
    }
}
