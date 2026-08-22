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

    // MARK: - Init

    init(trackRepository: TrackRepository, configRepository: ConfigRepository) {
        self.trackRepository = trackRepository
        self.configRepository = configRepository
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

                let local  = (try? await trackRepository.countLocalTracks())  ?? localCount
                let remote = (try? await trackRepository.countRemoteTracks()) ?? remoteCount
                guard !Task.isCancelled else { return }

                let availability = TrackPresentationAvailability.map(
                    tracks: result,
                    libraryRoot: libraryRoot,
                    fileExists: { FileManager.default.fileExists(atPath: $0.path) }
                )

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    displayedTracks = result
                    availabilityByTrackID = availability
                    localCount      = local
                    remoteCount     = remote
                    isLoading       = false
                    errorMessage    = nil
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
    @MainActor
    func loadTracks() async {
        await refreshLibraryRootSnapshot()
        scheduleRefresh()
        await refreshTask?.value
    }

    /// Refresh after external changes (import, download, delete).
    @MainActor
    func refresh() async {
        await loadTracks()
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
