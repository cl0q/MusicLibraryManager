import Foundation
import Observation

/// The data behind one track table: rows in display order, the selection and the sort.
///
/// Hosts hand it tracks (`setTracks`) in their natural order — load order, or the container's
/// own order — and the model builds rows and sorts them, off the main actor for big lists.
/// A refresh replaces the rows in place: the table keeps its identity, selection and scroll
/// position (UC-TABLE-08/09); the selection is never pruned by a filter, only by `remove(ids:)`.
///
/// Main-actor work per selection change is proportional to the selection, not to the list:
/// `indexByID`, `rowsToken` and `hasPlayableRows` are computed once per load/sort.
@MainActor
@Observable
final class TrackListModel {
    /// Rows in display order.
    private(set) var rows: [TrackRow] = []
    /// The rows' tracks in display order (commands, Play ‹view›, queue context).
    private(set) var tracks: [Track] = []
    /// The first rows have arrived; until then the table shows placeholder rows (UC-TABLE-09).
    private(set) var isLoaded = false
    /// The table's selection (`Set<Track.ID>`, UC-TABLE-01).
    var selection: Set<Int64> = []
    /// `nil` = natural order.
    private(set) var sortOrder: TrackSortOrder?

    /// Rows in natural order, as last given.
    @ObservationIgnored private(set) var sourceRows: [TrackRow] = []
    /// Display index per row id.
    @ObservationIgnored private(set) var indexByID: [Int64: Int] = [:]
    /// Changes whenever the rows or their order change (`TrackSelection.rowsToken`).
    @ObservationIgnored private(set) var rowsToken = 0
    /// Some row has a local file (Playback ▸ Play / Shuffle ‹view›).
    @ObservationIgnored private(set) var hasPlayableRows = false
    /// Sum of the rows' durations in seconds (status bar without SQL totals).
    @ObservationIgnored private(set) var totalDuration = 0
    @ObservationIgnored private var generation = 0

    /// Lists longer than this are built and sorted off the main actor.
    static let backgroundThreshold = 1_500

    init(sortOrder: TrackSortOrder? = nil) {
        self.sortOrder = sortOrder
    }

    // MARK: - Loading

    /// Replace the rows with `tracks` (natural order). Small lists commit before the first
    /// suspension point; big ones are prepared in the background and committed unless a newer
    /// load superseded them.
    ///
    /// - Parameter visibleIDs: show only these (a filter that keeps container positions —
    ///   a searched playlist still shows each track's playlist `#`, UC-TABLE-05).
    func setTracks(_ tracks: [Track], context: TrackRowBuildContext = .library, visibleIDs: Set<Int64>? = nil) async {
        generation += 1
        let token = generation
        let order = sortOrder
        let make: @Sendable () -> Prepared = {
            var rows = TrackRowBuilder.build(tracks, context: context)
            if let visibleIDs { rows = rows.filter { visibleIDs.contains($0.id) } }
            return Prepared.make(rows, order: order)
        }
        if tracks.count <= Self.backgroundThreshold {
            commit(make())
            return
        }
        let prepared = await Task.detached(priority: .userInitiated) { make() }.value
        guard token == generation else { return }
        commit(prepared)
    }

    /// Replace the rows at once (small lists only: menus built on the fly, tests).
    func setTracksNow(_ tracks: [Track], context: TrackRowBuildContext = .library) {
        generation += 1
        commit(Prepared.make(TrackRowBuilder.build(tracks, context: context), order: sortOrder))
    }

    /// Replace the rows with prebuilt rows (natural order).
    func setRows(_ newRows: [TrackRow]) async {
        generation += 1
        let token = generation
        let order = sortOrder
        if newRows.count <= Self.backgroundThreshold {
            commit(Prepared.make(newRows, order: order))
            return
        }
        let prepared = await Task.detached(priority: .userInitiated) { Prepared.make(newRows, order: order) }.value
        guard token == generation else { return }
        commit(prepared)
    }

    /// Change the sort; re-sorts the current rows (no reload).
    func setSortOrder(_ order: TrackSortOrder?) async {
        guard order != sortOrder else { return }
        sortOrder = order
        await setRows(sourceRows)
    }

    /// Remove rows in place (tracks deleted from the library or the container).
    func remove(ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        selection.subtract(ids)
        let kept = sourceRows.filter { !ids.contains($0.id) }
        guard kept.count != sourceRows.count else { return }
        generation += 1
        commit(Prepared.make(kept, order: sortOrder))
    }

    private func commit(_ prepared: Prepared) {
        sourceRows = prepared.source
        indexByID = prepared.indexByID
        rowsToken = prepared.token
        hasPlayableRows = prepared.hasPlayableRows
        totalDuration = prepared.totalDuration
        rows = prepared.rows
        tracks = prepared.tracks
        isLoaded = true
    }

    // MARK: - Selection (cost ∝ selection)

    /// Selected rows that are shown, in display order.
    func selectedRows(_ ids: Set<Int64>? = nil) -> [TrackRow] {
        let ids = ids ?? selection
        guard !ids.isEmpty else { return [] }
        if ids.count > rows.count / 4 {
            return rows.filter { ids.contains($0.id) }
        }
        return ids.compactMap { indexByID[$0] }.sorted().map { rows[$0] }
    }

    func row(id: Int64) -> TrackRow? {
        indexByID[id].map { rows[$0] }
    }

    // MARK: - Preparation (pure, off the main actor)

    struct Prepared: Sendable {
        let source: [TrackRow]
        let rows: [TrackRow]
        let tracks: [Track]
        let indexByID: [Int64: Int]
        let token: Int
        let hasPlayableRows: Bool
        let totalDuration: Int

        static func make(_ source: [TrackRow], order: TrackSortOrder?) -> Prepared {
            let rows = TrackRowSorter.sorted(source, by: order)
            var indexByID: [Int64: Int] = [:]
            indexByID.reserveCapacity(rows.count)
            var hasher = Hasher()
            hasher.combine(rows.count)
            var playable = false
            var duration = 0
            for (index, row) in rows.enumerated() {
                indexByID[row.id] = index
                hasher.combine(row.id)
                if !playable, row.availability == .local { playable = true }
                duration += max(row.track.duration ?? 0, 0)
            }
            return Prepared(
                source: source,
                rows: rows,
                tracks: rows.map(\.track),
                indexByID: indexByID,
                token: hasher.finalize(),
                hasPlayableRows: playable,
                totalDuration: duration
            )
        }
    }
}
