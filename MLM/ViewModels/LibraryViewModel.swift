import Foundation
import GRDB

// MARK: - Sort descriptor

/// Describes how a track list is sorted in SQL (Folders still uses it).
struct TrackSortDescriptor: Equatable {
    var column: SortColumn
    var ascending: Bool

    mutating func toggle(column newColumn: SortColumn) {
        if self.column == newColumn {
            ascending.toggle()
        } else {
            self.column = newColumn
            ascending = true
        }
    }
}

// MARK: - ViewModel

/// All Tracks (V-LIB): one table of every track, filtered in SQL by the availability scope
/// (`All · Local · Not downloaded · Download failed · File missing`, DEC-011) and the
/// toolbar's in-place text filter. The rows go to its `TrackListModel`, which sorts them in
/// memory and keeps the selection; counts and totals come from one SQL aggregate
/// (`TrackScopeSummary`, UC-TABLE-21). Every refresh updates in place — no spinner after the
/// first load (UC-TABLE-09) — and touches no disk (UC-TABLE-20).
@MainActor
@Observable
final class LibraryViewModel {
    /// The table's rows, sort and selection.
    let list: TrackListModel

    /// The availability scope shown. Changing it keeps the selection (UC-TABLE-08: it
    /// survives filters; rows that leave the scope come back selected).
    var scope: TrackAvailabilityScope = .all {
        didSet {
            if oldValue != scope { scheduleRefresh() }
        }
    }

    /// The toolbar field's filter for All Tracks — text and tokens, applied in SQL (W2-I).
    /// Debounced: changes trigger a refresh after 200 ms idle.
    var searchFilter = SearchFilter() {
        didSet {
            guard oldValue != searchFilter else { return }
            debouncer.debounce { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
    }

    /// The filter's text alone (fixtures and older callers).
    var searchQuery: String {
        get { searchFilter.text }
        set { searchFilter = SearchFilter(text: newValue, tokens: searchFilter.tokens) }
    }

    /// Scope counts, durations and the library size; `nil` until the first load (the scope
    /// bar shows its words only).
    private(set) var summary: TrackScopeSummary?
    private(set) var errorMessage: String?

    /// Live count per scope for the current search (the scope bar).
    var counts: TrackAvailabilityCounts? { summary?.counts }

    /// Every track in the library, ignoring scope and search (window subtitle, sidebar footer).
    var libraryTrackCount: Int { summary?.libraryCount ?? 0 }

    /// Count and duration of what the table shows — the scope and the search (status bar,
    /// UC-STATUS-02); `nil` falls back to the loaded rows.
    var totals: TrackListTotals? {
        guard let summary, summary.durations[scope] != nil else { return nil }
        return summary.totals(for: scope)
    }

    /// The library has no tracks at all (UC-EMPTY-01), as of the last load.
    var isLibraryEmpty: Bool { summary.map { $0.libraryCount == 0 } ?? false }

    /// The tracks shown, in display order — what Playback ▸ Play / Shuffle All Tracks play.
    var displayedTracks: [Track] { list.tracks }

    var selectedTrackIDs: Set<Int64> {
        get { list.selection }
        set { list.selection = newValue }
    }

    var isLoaded: Bool { list.isLoaded }

    // MARK: - Dependencies

    @ObservationIgnored private let trackRepository: TrackRepository
    @ObservationIgnored private let explicitQueries: TrackScopeQueries?
    @ObservationIgnored private let debouncer = Debouncer(delay: .milliseconds(200))
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    @ObservationIgnored private var lastLoaded: (scope: TrackAvailabilityScope, filter: SearchFilter)?

    /// - Parameter scopeQueries: the aggregate queries; `nil` = the open library's
    ///   (`TrackScopeQueries.current()`). Tests pass their temporary database's.
    init(trackRepository: TrackRepository, configRepository _: ConfigRepository, scopeQueries: TrackScopeQueries? = nil) {
        self.trackRepository = trackRepository
        self.explicitQueries = scopeQueries
        self.list = TrackListModel(sortOrder: TrackListConfiguration.allTracks(activate: nil, totals: nil).defaultSort)
    }

    /// Static fixtures: preloads rows without starting a fetch.
    convenience init(
        trackRepository: TrackRepository,
        configRepository: ConfigRepository,
        preloadedTracks: [Track],
        scope: TrackAvailabilityScope = .all
    ) {
        self.init(trackRepository: trackRepository, configRepository: configRepository)
        self.scope = scope
        list.setTracksNow(preloadedTracks.filter { scope.contains($0.availability()) })
        lastLoaded = (scope, SearchFilter())
    }

    private var scopeQueries: TrackScopeQueries? { explicitQueries ?? TrackScopeQueries.current() }

    // MARK: - Data loading

    /// Cancel any in-flight fetch and start a new one for the current scope and search.
    func scheduleRefresh() {
        refreshTask?.cancel()
        summaryTask?.cancel()
        let scope = self.scope
        let filter = searchFilter
        let repository = trackRepository
        let queries = scopeQueries
        refreshTask = Task { [weak self] in
            let start = Date()
            do {
                let rows: [Track]
                if let queries {
                    rows = try await TrackSearchQueries(database: queries.database).fetchTracks(scope: scope, filter: filter)
                } else {
                    rows = try await repository.fetchTracks(scope: scope, search: Self.text(of: filter))
                }
                guard !Task.isCancelled else { return }
                let summary = try await Self.loadSummary(queries: queries, repository: repository, filter: filter)
                guard !Task.isCancelled, let self else { return }
                await self.list.setTracks(rows)
                guard !Task.isCancelled else { return }
                self.summary = summary
                self.errorMessage = nil
                self.lastLoaded = (scope, filter)
                AppLogger.shared.info(
                    "library refresh: \(rows.count) rows in \(Int(Date().timeIntervalSince(start) * 1000))ms (scope=\(scope.rawValue))",
                    source: "perf"
                )
            } catch {
                guard !Task.isCancelled, let self else { return }
                // Keep the rows on screen (in place); the failure is logged.
                self.errorMessage = error.localizedDescription
                AppLogger.shared.error("library refresh failed: \(error.localizedDescription)", source: "Library")
            }
        }
    }

    /// First load (or a no-op when the same scope/search is already loaded).
    func loadTracks() async {
        if let lastLoaded, lastLoaded.scope == scope, lastLoaded.filter == searchFilter, list.isLoaded {
            return
        }
        scheduleRefresh()
        await refreshTask?.value
    }

    /// Refresh after external changes (import, download, delete, file check) — in place.
    func refresh() async {
        debouncer.cancel() // a pending debounced refresh must not cancel this explicit one
        scheduleRefresh()
        await refreshTask?.value
    }

    /// Remove tracks in place without a row refetch (the counts follow from SQL).
    func removeTracks(ids: Set<Int64>) {
        list.remove(ids: ids)
        refreshSummary()
    }

    /// Re-read only the counts and totals (rows unchanged).
    private func refreshSummary() {
        summaryTask?.cancel()
        let filter = searchFilter
        let repository = trackRepository
        let queries = scopeQueries
        summaryTask = Task { [weak self] in
            guard let summary = try? await Self.loadSummary(
                queries: queries, repository: repository, filter: filter
            ), !Task.isCancelled else { return }
            self?.summary = summary
        }
    }

    /// Waits for a counts-only refresh started by `removeTracks` (tests).
    func waitForSummary() async {
        await summaryTask?.value
    }

    /// The scope summary from SQL; without aggregate queries (fixtures) the counts alone.
    private static func loadSummary(
        queries: TrackScopeQueries?,
        repository: TrackRepository,
        filter: SearchFilter
    ) async throws -> TrackScopeSummary {
        if let queries { return try await TrackSearchQueries(database: queries.database).scopeSummary(filter: filter) }
        let search = text(of: filter)
        let counts = try await repository.availabilityCounts(search: search)
        let library = search == nil ? counts.all : try await repository.availabilityCounts().all
        return TrackScopeSummary(counts: counts, durations: [.all: counts.totalDuration], libraryCount: library)
    }

    /// Free words only, for the repository fallback without aggregate queries (fixtures).
    private nonisolated static func text(of filter: SearchFilter) -> String? {
        let text = filter.parsed.freeText
        return text.isEmpty ? nil : text
    }

    // MARK: - Selection helpers

    var hasSelection: Bool { !selectedTrackIDs.isEmpty }
    var selectionCount: Int { selectedTrackIDs.count }

    var selectedTracks: [Track] {
        list.selectedRows().map(\.track)
    }

    /// Show `trackID` selected (Go to Current Track ⌘L): keeps the scope when the track is in
    /// it, else switches to `All` (UC-TABLE-08 — the scope is a filter, not a place).
    func reveal(trackID: Int64, availability: TrackAvailability) {
        if !scope.contains(availability) { scope = .all }
        selectedTrackIDs = [trackID]
    }
}
