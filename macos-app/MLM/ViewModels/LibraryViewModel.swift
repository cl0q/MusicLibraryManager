import Foundation
import GRDB

// MARK: - Sort descriptor

/// Describes how the library table is sorted.
struct TrackSortDescriptor: Equatable {
    enum Column: String, CaseIterable {
        case title, artist, album, format, bitrate, duration, genre, year, energy, dateAdded
    }

    var column: Column
    var ascending: Bool

    /// Toggle sort direction, or switch to a new column (ascending default).
    mutating func toggle(column newColumn: Column) {
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
/// Owns track data, search state, tab state, sort state, and selection.
/// Fetches from `TrackRepository` via the `DependencyContainer`.
@Observable
final class LibraryViewModel {
    // MARK: - Published state

    /// Tracks currently visible in the table (filtered, sorted).
    private(set) var displayedTracks: [Track] = []

    /// All tracks for the current tab (before search filter).
    private(set) var allTracks: [Track] = []

    /// Counts for tab badges.
    private(set) var localCount: Int = 0
    private(set) var remoteCount: Int = 0

    /// Current tab selection.
    var selectedTab: LibraryTab = .local {
        didSet {
            if oldValue != selectedTab {
                Task { await loadTracks() }
            }
        }
    }

    /// Search query text (bound to FilterBar).
    var searchQuery: String = "" {
        didSet {
            debouncer.debounce { [weak self] in
                await self?.applyFilter()
            }
        }
    }

    /// Current sort descriptor.
    var sortDescriptor = TrackSortDescriptor(column: .artist, ascending: true) {
        didSet {
            applySort()
        }
    }

    /// Selected track IDs for multi-select.
    var selectedTrackIDs: Set<Int64> = []

    /// Whether data is loading.
    private(set) var isLoading = false

    /// Error message if load fails.
    private(set) var errorMessage: String?

    // MARK: - Dependencies

    private let trackRepository: TrackRepository
    private let debouncer = Debouncer(delay: .milliseconds(200))

    // MARK: - Init

    init(trackRepository: TrackRepository) {
        self.trackRepository = trackRepository
    }

    // MARK: - Data loading

    /// Load tracks from the database for the current tab.
    @MainActor
    func loadTracks() async {
        isLoading = true
        errorMessage = nil

        do {
            // Fetch tracks based on tab
            switch selectedTab {
            case .local:
                allTracks = try await trackRepository.fetchLocalTracks()
            case .remote:
                allTracks = try await trackRepository.fetchRemoteTracks()
            }

            // Fetch counts for both tabs
            localCount = try await trackRepository.countLocalTracks()
            remoteCount = try await trackRepository.countRemoteTracks()

            // Apply current search filter + sort
            applyFilterAndSort()
        } catch {
            errorMessage = error.localizedDescription
            allTracks = []
            displayedTracks = []
        }

        isLoading = false
    }

    /// Refresh data (e.g., after import, download, or delete).
    @MainActor
    func refresh() async {
        await loadTracks()
    }

    // MARK: - Filtering

    /// Apply the search filter to allTracks, then sort.
    @MainActor
    private func applyFilter() {
        applyFilterAndSort()
    }

    /// Combined filter + sort pass.
    private func applyFilterAndSort() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()

        if query.isEmpty {
            displayedTracks = allTracks
        } else {
            displayedTracks = allTracks.filter { track in
                track.title.lowercased().contains(query) ||
                track.artist.lowercased().contains(query) ||
                track.album.lowercased().contains(query) ||
                (track.genre?.lowercased().contains(query) ?? false)
            }
        }

        applySort()
    }

    // MARK: - Sorting

    /// Sort displayedTracks by the current sort descriptor.
    private func applySort() {
        displayedTracks.sort { a, b in
            let result: ComparisonResult
            switch sortDescriptor.column {
            case .title:
                result = a.title.localizedCaseInsensitiveCompare(b.title)
            case .artist:
                result = a.artist.localizedCaseInsensitiveCompare(b.artist)
            case .album:
                result = a.album.localizedCaseInsensitiveCompare(b.album)
            case .format:
                result = a.format.localizedCaseInsensitiveCompare(b.format)
            case .bitrate:
                result = compare(a.bitrate, b.bitrate)
            case .duration:
                result = compare(a.duration, b.duration)
            case .genre:
                result = (a.genre ?? "").localizedCaseInsensitiveCompare(b.genre ?? "")
            case .year:
                result = compare(a.year, b.year)
            case .energy:
                result = compare(a.energyBucket, b.energyBucket)
            case .dateAdded:
                result = (a.dateAdded ?? "").compare(b.dateAdded ?? "")
            }
            return sortDescriptor.ascending
                ? result == .orderedAscending
                : result == .orderedDescending
        }
    }

    /// Compare two optional Ints, treating nil as lowest.
    private func compare(_ a: Int?, _ b: Int?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (a?, b?):
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            return .orderedSame
        }
    }

    // MARK: - Sort cycling

    /// Toggle sort on a column (called from table header tap).
    func toggleSort(column: TrackSortDescriptor.Column) {
        sortDescriptor.toggle(column: column)
    }

    // MARK: - Selection helpers

    /// Whether any tracks are selected.
    var hasSelection: Bool {
        !selectedTrackIDs.isEmpty
    }

    /// Number of selected tracks.
    var selectionCount: Int {
        selectedTrackIDs.count
    }

    /// Get the selected Track objects.
    var selectedTracks: [Track] {
        displayedTracks.filter { track in
            guard let id = track.id else { return false }
            return selectedTrackIDs.contains(id)
        }
    }
}
