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

// MARK: - View tab

/// Local vs. Remote tab state (until W2-B's availability scope bar replaces it).
enum LibraryTab: String, CaseIterable, Identifiable {
    case local
    case remote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: "Local"
        case .remote: "Remote"
        }
    }
}

// MARK: - ViewModel

/// All Tracks: filters in SQL (tab, search), hands the rows to its `TrackListModel`, which
/// sorts them in memory and keeps the selection. Counts and totals come from SQL aggregates
/// (UC-TABLE-21). Refreshes update the rows in place — no spinner after the first load
/// (UC-TABLE-09); availability is persisted (no disk access, UC-TABLE-20).
@MainActor
@Observable
final class LibraryViewModel {
    /// The table's rows, sort and selection.
    let list: TrackListModel

    private(set) var localCount = 0
    private(set) var remoteCount = 0
    /// Per-availability counts of the whole library for the current search (W2-B's scope bar).
    private(set) var counts = TrackAvailabilityCounts()
    /// Count and duration of what the table shows (status bar, UC-STATUS-02).
    private(set) var totals: TrackListTotals?
    private(set) var errorMessage: String?

    /// The tracks shown, in display order.
    var displayedTracks: [Track] { list.tracks }

    /// Changing the tab keeps the selection (UC-TABLE-08: it survives filters).
    var selectedTab: LibraryTab = .local {
        didSet {
            if oldValue != selectedTab { scheduleRefresh() }
        }
    }

    /// Debounced: search changes trigger a refresh after 200 ms idle.
    var searchQuery: String = "" {
        didSet {
            guard oldValue != searchQuery else { return }
            debouncer.debounce { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
    }

    var selectedTrackIDs: Set<Int64> {
        get { list.selection }
        set { list.selection = newValue }
    }

    var isLoaded: Bool { list.isLoaded }

    // MARK: - Dependencies

    @ObservationIgnored private let trackRepository: TrackRepository
    @ObservationIgnored private let debouncer = Debouncer(delay: .milliseconds(200))
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastLoaded: (tab: LibraryTab, search: String)?

    init(trackRepository: TrackRepository, configRepository: ConfigRepository) {
        self.trackRepository = trackRepository
        self.list = TrackListModel(sortOrder: TrackListConfiguration.allTracks(activate: nil, totals: nil).defaultSort)
    }

    /// Static fixtures: preloads rows without starting a fetch.
    convenience init(
        trackRepository: TrackRepository,
        configRepository: ConfigRepository,
        preloadedTracks: [Track],
        selectedTab: LibraryTab = .local,
        localCount: Int? = nil,
        remoteCount: Int? = nil
    ) {
        self.init(trackRepository: trackRepository, configRepository: configRepository)
        self.selectedTab = selectedTab
        self.localCount = localCount ?? preloadedTracks.filter(\.isLocal).count
        self.remoteCount = remoteCount ?? preloadedTracks.filter(\.isRemote).count
        list.setTracksNow(preloadedTracks)
        lastLoaded = (selectedTab, "")
    }

    // MARK: - Data loading

    /// Cancel any in-flight fetch and start a new one for the current state.
    func scheduleRefresh() {
        refreshTask?.cancel()
        let tab = selectedTab
        let search = searchQuery
        let repository = trackRepository
        refreshTask = Task { [weak self] in
            let start = Date()
            do {
                let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
                let result = try await repository.fetchForLibrary(
                    tab: tab,
                    search: trimmed.isEmpty ? nil : trimmed,
                    sortBy: .dateAdded,
                    ascending: false
                )
                guard !Task.isCancelled else { return }
                let split = try await repository.countTracksByAvailability()
                let counts = try await repository.availabilityCounts(search: trimmed.isEmpty ? nil : trimmed)
                let totals = try await repository.libraryTotals(tab: tab, search: trimmed.isEmpty ? nil : trimmed)
                guard !Task.isCancelled, let self else { return }
                await self.list.setTracks(result)
                guard !Task.isCancelled else { return }
                self.localCount = split.local
                self.remoteCount = split.remote
                self.counts = counts
                self.totals = totals
                self.errorMessage = nil
                self.lastLoaded = (tab, search)
                AppLogger.shared.info(
                    "library refresh: \(result.count) rows in \(Int(Date().timeIntervalSince(start) * 1000))ms (tab=\(tab.rawValue))",
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

    /// First load (or a no-op when the same tab/search is already loaded).
    func loadTracks() async {
        if let lastLoaded, lastLoaded.tab == selectedTab, lastLoaded.search == searchQuery, list.isLoaded {
            return
        }
        scheduleRefresh()
        await refreshTask?.value
    }

    /// Refresh after external changes (import, download, delete, file check) — in place.
    func refresh() async {
        scheduleRefresh()
        await refreshTask?.value
    }

    /// Remove tracks in place without a SQL refetch.
    func removeTracks(ids: Set<Int64>) {
        list.remove(ids: ids)
    }

    // MARK: - Selection helpers

    var hasSelection: Bool { !selectedTrackIDs.isEmpty }
    var selectionCount: Int { selectedTrackIDs.count }

    var selectedTracks: [Track] {
        list.selectedRows().map(\.track)
    }
}
