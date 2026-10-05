import Foundation
import GRDB

// MARK: - Sort descriptor

/// Describes how the library table is sorted.
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

/// Local vs. Remote tab state.
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

/// ViewModel for the Library Browser.
///
/// All filtering and sorting happens in SQL — never in-memory on the 11k track array.
@Observable
final class LibraryViewModel {
    // MARK: - Published state

    private(set) var displayedTracks: [Track] = []
    private(set) var localCount: Int = 0
    private(set) var remoteCount: Int = 0
    private(set) var availabilityByTrackID: [Int64: TrackAvailability] = [:]

    var selectedTab: LibraryTab = .local {
        didSet {
            if oldValue != selectedTab {
                selectedTrackIDs = []
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
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

    /// Immediate: sort changes trigger a new SQL fetch.
    var sortDescriptor = TrackSortDescriptor(column: .dateAdded, ascending: false) {
        didSet {
            if oldValue != sortDescriptor {
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
        }
    }

    var selectedTrackIDs: Set<Int64> = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    // MARK: - Dependencies

    private let trackRepository: TrackRepository
    private let configRepository: ConfigRepository
    private let debouncer = Debouncer(delay: .milliseconds(200))
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    private var libraryRootSnapshot: URL?

    /// Parameters of the last successful fetch — used to skip redundant refetches
    /// when the view reappears with the same tab/search/sort/libraryRoot.
    private struct FetchSignature: Equatable {
        var tab: LibraryTab
        var search: String
        var sortColumn: SortColumn
        var sortAscending: Bool
        var libraryRoot: URL?
    }
    private var lastFetchSignature: FetchSignature?

    // MARK: - Init

    init(trackRepository: TrackRepository, configRepository: ConfigRepository) {
        self.trackRepository = trackRepository
        self.configRepository = configRepository
    }

    /// Deterministic construction path for static UI fixtures. It preloads
    /// presentation state only; callers retain the same repository dependencies
    /// and no fetch, service, or playback work starts from this initializer.
    init(
        trackRepository: TrackRepository,
        configRepository: ConfigRepository,
        preloadedTracks: [Track],
        selectedTab: LibraryTab = .local,
        availabilityByTrackID: [Int64: TrackAvailability] = [:],
        localCount: Int? = nil,
        remoteCount: Int? = nil
    ) {
        self.trackRepository = trackRepository
        self.configRepository = configRepository
        self.selectedTab = selectedTab
        self.displayedTracks = preloadedTracks
        self.localCount = localCount ?? preloadedTracks.filter(\.isLocal).count
        self.remoteCount = remoteCount ?? preloadedTracks.filter(\.isRemote).count
        self.availabilityByTrackID = availabilityByTrackID
    }

    // MARK: - Data loading

    /// Cancel any in-flight fetch and start a new one for the current state.
    @MainActor
    func scheduleRefresh() {
        refreshTask?.cancel()
        isLoading = true

        let tab    = selectedTab
        let search = searchQuery
        let sort   = sortDescriptor
        let libraryRoot = libraryRootSnapshot

        refreshTask = Task { [weak self] in
            guard let self else { return }

            let start = Date()
            do {
                let result = try await trackRepository.fetchForLibrary(
                    tab: tab,
                    search: search.isEmpty ? nil : search,
                    sortBy: sort.column,
                    ascending: sort.ascending
                )
                guard !Task.isCancelled else { return }

                let counts = try? await trackRepository.countTracksByAvailability()
                let local  = counts?.local  ?? localCount
                let remote = counts?.remote ?? remoteCount
                guard !Task.isCancelled else { return }

                let availability = TrackAvailability.byTrackID(result)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    displayedTracks = result
                    availabilityByTrackID = availability
                    localCount      = local
                    remoteCount     = remote
                    isLoading       = false
                    errorMessage    = nil
                    lastFetchSignature = FetchSignature(
                        tab: tab,
                        search: search,
                        sortColumn: sort.column,
                        sortAscending: sort.ascending,
                        libraryRoot: libraryRoot
                    )
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    AppLogger.shared.info(
                        "library refresh: \(result.count) rows in \(ms)ms (sort=\(sort.column.rawValue), tab=\(tab.rawValue))",
                        source: "perf"
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    errorMessage    = error.localizedDescription
                    displayedTracks = []
                    availabilityByTrackID = [:]
                    isLoading       = false
                }
            }
        }
    }

    /// Await the current refresh to completion (used by `.task` in views).
    ///
    /// Cache guard: if the fetch parameters (tab, search, sort, library root)
    /// match the last successful fetch and tracks are already populated, skip
    /// the SQL query entirely. This makes navigating back to the Library instant.
    @MainActor
    func loadTracks() async {
        // Fast path: if we already have a snapshot and the signature matches,
        // skip the configRepository round-trip entirely.
        if libraryRootSnapshot != nil {
            let signature = FetchSignature(
                tab: selectedTab,
                search: searchQuery,
                sortColumn: sortDescriptor.column,
                sortAscending: sortDescriptor.ascending,
                libraryRoot: libraryRootSnapshot
            )
            if signature == lastFetchSignature, !displayedTracks.isEmpty {
                return
            }
        }

        await refreshLibraryRootSnapshot()

        let signature = FetchSignature(
            tab: selectedTab,
            search: searchQuery,
            sortColumn: sortDescriptor.column,
            sortAscending: sortDescriptor.ascending,
            libraryRoot: libraryRootSnapshot
        )
        if signature == lastFetchSignature, !displayedTracks.isEmpty {
            return
        }

        scheduleRefresh()
        await refreshTask?.value
    }

    /// Refresh after external changes (import, download, delete).
    /// Bypasses the cache guard — forces a full SQL refetch.
    @MainActor
    func refresh() async {
        await refreshLibraryRootSnapshot()
        lastFetchSignature = nil
        scheduleRefresh()
        await refreshTask?.value
    }

    /// Remove tracks in-place without a full SQL refetch.
    @MainActor
    func removeTracks(ids: Set<Int64>) {
        displayedTracks.removeAll { track in
            guard let id = track.id else { return false }
            return ids.contains(id)
        }
        availabilityByTrackID = availabilityByTrackID.filter { !ids.contains($0.key) }
        selectedTrackIDs.subtract(ids)
    }

    // MARK: - Sort

    func toggleSort(column: SortColumn) {
        sortDescriptor.toggle(column: column)
    }

    // MARK: - Selection helpers

    var hasSelection: Bool { !selectedTrackIDs.isEmpty }
    var selectionCount: Int { selectedTrackIDs.count }

    var selectedTracks: [Track] {
        displayedTracks.filter { track in
            guard let id = track.id else { return false }
            return selectedTrackIDs.contains(id)
        }
    }

    // MARK: - Availability

    private func refreshLibraryRootSnapshot() async {
        guard let rootPath = (try? await configRepository.getLibraryRoot()) ?? nil,
              !rootPath.isEmpty else {
            libraryRootSnapshot = nil
            return
        }

        libraryRootSnapshot = URL(fileURLWithPath: rootPath)
    }
}
