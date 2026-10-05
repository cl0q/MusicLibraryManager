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
    /// Some row has a local file (persisted; ignores the drive — see `hasPlayableRows(live:)`).
    @ObservationIgnored private(set) var hasPlayableRows = false
    /// Where the local rows' files are (a handful of values: library folder, other volumes).
    @ObservationIgnored private(set) var localFileLocations: Set<TrackFileLocation> = []
    /// Sum of the rows' durations in seconds (status bar without SQL totals).
    @ObservationIgnored private(set) var totalDuration = 0
    @ObservationIgnored private var generation = 0

    /// Lists longer than this are built and sorted off the main actor.
    static let backgroundThreshold = 1_500

    init(sortOrder: TrackSortOrder? = nil) {
        self.sortOrder = sortOrder
    }

    // MARK: - Loading

    /// What the rows are made from: the latest tracks (and how to build them) or rows. A sort
    /// or a removal always re-prepares from the **latest** input, so a sort while a big load is
    /// still being prepared re-sorts the new rows instead of dropping them (W2-A review S2).
    enum Input: Sendable {
        case tracks([Track], TrackRowBuildContext, visibleIDs: Set<Int64>?)
        case rows([TrackRow])

        var count: Int {
            switch self {
            case .tracks(let tracks, _, _): tracks.count
            case .rows(let rows): rows.count
            }
        }

        func buildRows() -> [TrackRow] {
            switch self {
            case .tracks(let tracks, let context, let visibleIDs):
                let rows = TrackRowBuilder.build(tracks, context: context)
                guard let visibleIDs else { return rows }
                return rows.filter { visibleIDs.contains($0.id) }
            case .rows(let rows):
                return rows
            }
        }

        func removing(_ ids: Set<Int64>) -> Input {
            switch self {
            case .tracks(let tracks, let context, let visibleIDs):
                .tracks(tracks.filter { !($0.id.map(ids.contains) ?? false) }, context, visibleIDs: visibleIDs)
            case .rows(let rows):
                .rows(rows.filter { !ids.contains($0.id) })
            }
        }
    }

    /// The newest input; `nil` until the first `setTracks` / `setRows`.
    @ObservationIgnored private var latestInput: Input? {
        didSet { inputVersion += 1 }
    }
    @ObservationIgnored private var inputVersion = 0

    /// Replace the rows with `tracks` (natural order). Small lists commit before the first
    /// suspension point; big ones are prepared in the background and committed unless a newer
    /// input or sort superseded them (then the newer one commits).
    ///
    /// - Parameter visibleIDs: show only these (a filter that keeps container positions —
    ///   a searched playlist still shows each track's playlist `#`, UC-TABLE-05).
    func setTracks(_ tracks: [Track], context: TrackRowBuildContext = .library, visibleIDs: Set<Int64>? = nil) async {
        latestInput = .tracks(tracks, context, visibleIDs: visibleIDs)
        await prepareLatest()
    }

    /// Replace the rows at once (small lists only: menus built on the fly, fixtures).
    func setTracksNow(_ tracks: [Track], context: TrackRowBuildContext = .library) {
        let input = Input.tracks(tracks, context, visibleIDs: nil)
        latestInput = input
        generation += 1
        commit(Prepared.make(input.buildRows(), order: sortOrder))
    }

    /// Replace the rows with prebuilt rows (natural order).
    func setRows(_ newRows: [TrackRow]) async {
        latestInput = .rows(newRows)
        await prepareLatest()
    }

    /// Change the sort and re-sort the latest input. Before the first load only the order is
    /// stored — nothing is committed, so the table keeps its placeholder rows (no false
    /// empty state).
    func setSortOrder(_ order: TrackSortOrder?) async {
        guard order != sortOrder else { return }
        sortOrder = order
        guard latestInput != nil else { return }
        await prepareLatest()
    }

    /// Remove rows in place (tracks deleted from the library or the container), also from a
    /// load still being prepared.
    func remove(ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        selection.subtract(ids)
        guard let input = latestInput else { return }
        latestInput = input.removing(ids)
        guard isLoaded else { return }  // the pending load picks the removal up
        if input.count <= Self.backgroundThreshold {
            generation += 1
            commit(Prepared.make(latestInput?.buildRows() ?? [], order: sortOrder))
        } else {
            Task { await prepareLatest() }
        }
    }

    private func prepareLatest() async {
        guard let input = latestInput else { return }
        let version = inputVersion
        generation += 1
        let token = generation
        let order = sortOrder
        let prepared: Prepared
        if input.count <= Self.backgroundThreshold {
            prepared = Prepared.make(input.buildRows(), order: order)
        } else {
            prepared = await Task.detached(priority: .userInitiated) {
                Prepared.make(input.buildRows(), order: order)
            }.value
            guard token == generation else { return }
        }
        commit(prepared)
        if version == inputVersion {
            // Later sorts reuse the built rows.
            latestInput = .rows(prepared.source)
        } else {
            // The input changed while this was prepared (a removal): prepare the newest.
            await prepareLatest()
        }
    }

    private func commit(_ prepared: Prepared) {
        sourceRows = prepared.source
        indexByID = prepared.indexByID
        rowsToken = prepared.token
        hasPlayableRows = prepared.hasPlayableRows
        localFileLocations = prepared.localFileLocations
        totalDuration = prepared.totalDuration
        rows = prepared.rows
        tracks = prepared.tracks
        isLoaded = true
    }

    /// Some row can play **now**: a local file not on the library's disk while it is away
    /// (Playback ▸ Play / Shuffle ‹view›, S7).
    func hasPlayableRows(live: TrackTableLiveState) -> Bool {
        guard let offline = live.offlineVolumePath else { return hasPlayableRows }
        return localFileLocations.contains { !$0.isOnVolume(offline) }
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

    // MARK: - Scrolling (seam, W2-C)

    /// A request for the table to scroll a row into view (Go to Current Track ⌘L).
    struct ScrollTarget: Equatable {
        let rowID: Int64
        fileprivate let request = UUID()
    }

    /// The latest scroll request; the table scrolls (instantly) when it changes.
    private(set) var scrollTarget: ScrollTarget?

    /// Scroll the row with `id` into view (the selection is the caller's).
    func scrollTo(_ id: Int64) {
        scrollTarget = ScrollTarget(rowID: id)
    }

    // MARK: - Preparation (pure, off the main actor)

    struct Prepared: Sendable {
        let source: [TrackRow]
        let rows: [TrackRow]
        let tracks: [Track]
        let indexByID: [Int64: Int]
        let token: Int
        let hasPlayableRows: Bool
        let localFileLocations: Set<TrackFileLocation>
        let totalDuration: Int

        static func make(_ source: [TrackRow], order: TrackSortOrder?) -> Prepared {
            let rows = TrackRowSorter.sorted(source, by: order)
            var indexByID: [Int64: Int] = [:]
            indexByID.reserveCapacity(rows.count)
            var hasher = Hasher()
            hasher.combine(rows.count)
            var playable = false
            var locations: Set<TrackFileLocation> = []
            var duration = 0
            for (index, row) in rows.enumerated() {
                indexByID[row.id] = index
                hasher.combine(row.id)
                if row.availability == .local {
                    playable = true
                    locations.insert(row.fileLocation)
                }
                duration += max(row.track.duration ?? 0, 0)
            }
            return Prepared(
                source: source,
                rows: rows,
                tracks: rows.map(\.track),
                indexByID: indexByID,
                token: hasher.finalize(),
                hasPlayableRows: playable,
                localFileLocations: locations,
                totalDuration: duration
            )
        }
    }
}
