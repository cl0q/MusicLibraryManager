import AppKit
import Foundation

// MARK: - Folder tree node

/// A node in the folder tree hierarchy.
///
/// Each node represents an `Artist` or `Artist/Album` directory derived
/// from `organized_path` values in the tracks table.
/// Children are lazily loaded on expansion.
@Observable
final class FolderNode: Identifiable, Hashable {
    let id: String       // Full path, e.g. "Artist/Album"
    let name: String     // Display name, e.g. "Album"
    var children: [FolderNode]?  // nil = not loaded yet
    var trackCount: Int = 0
    var isLoading = false

    /// Whether this node has been expanded and children loaded.
    var isLoaded: Bool { children != nil }

    init(id: String, name: String, children: [FolderNode]? = nil, trackCount: Int = 0) {
        self.id = id
        self.name = name
        self.children = children
        self.trackCount = trackCount
    }

    // MARK: - Hashable / Equatable

    static func == (lhs: FolderNode, rhs: FolderNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - ViewModel

/// ViewModel for the Folder Browser (Phase 7).
///
/// Builds a hierarchical folder tree from `organized_path` values.
/// Structure follows the convention: `Artist/Album/track.ext`.
///
/// ## Responsibilities
/// - Build root-level folder nodes (artist folders)
/// - Lazy-load children (album folders) on expansion
/// - Fetch tracks for a selected folder
/// - Support search filtering on folder names
/// - Track selection state for the split pane
@Observable
final class FolderViewModel {
    // MARK: - Published state

    /// Root-level folder nodes (artists).
    private(set) var rootNodes: [FolderNode] = []

    /// All root nodes (before search filter).
    private(set) var allRootNodes: [FolderNode] = []

    /// Tracks in the currently selected folder.
    private(set) var tracksInFolder: [Track] = []

    /// Currently selected folder path.
    var selectedFolderPath: String? = nil {
        didSet {
            if oldValue != selectedFolderPath {
                Task { await loadTracksForSelectedFolder() }
            }
        }
    }

    /// Search query for filtering folder names.
    var searchQuery: String = "" {
        didSet {
            applyFilter()
        }
    }

    /// Sort descriptor for the tracks table.
    var sortDescriptor = TrackSortDescriptor(column: .title, ascending: true) {
        didSet {
            applyTrackSort()
        }
    }

    /// Selected track IDs for multi-select.
    var selectedTrackIDs: Set<Int64> = []

    /// Whether data is loading.
    private(set) var isLoading = false

    /// Error message if load fails.
    private(set) var errorMessage: String?

    /// Total track count across all folders.
    private(set) var totalTrackCount: Int = 0

    /// Number of artist folders.
    var artistCount: Int { allRootNodes.count }

    // MARK: - Dependencies

    private let trackRepository: TrackRepository

    // MARK: - Init

    init(trackRepository: TrackRepository) {
        self.trackRepository = trackRepository
    }

    // MARK: - Load tree

    /// Load the root-level folder tree (artist folders).
    @MainActor
    func loadRootFolders() async {
        isLoading = true
        errorMessage = nil

        do {
            let artistNames = try await trackRepository.fetchChildFolders(under: "")
            totalTrackCount = try await trackRepository.countLocalTracks()

            var nodes: [FolderNode] = []
            for name in artistNames {
                let count = try await trackRepository.countTracks(in: name)
                let node = FolderNode(id: name, name: name, trackCount: count)
                nodes.append(node)
            }

            allRootNodes = nodes
            applyFilter()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Lazy-load children for a node on expansion.
    @MainActor
    func loadChildren(for node: FolderNode) async {
        guard !node.isLoaded else { return }
        node.isLoading = true

        do {
            let childNames = try await trackRepository.fetchChildFolders(under: node.id)

            var children: [FolderNode] = []
            for name in childNames {
                let fullPath = "\(node.id)/\(name)"
                let count = try await trackRepository.countTracks(in: fullPath)
                children.append(FolderNode(id: fullPath, name: name, trackCount: count))
            }

            node.children = children
        } catch {
            node.children = []
        }

        node.isLoading = false
    }

    // MARK: - Track loading

    /// Load tracks for the selected folder.
    @MainActor
    private func loadTracksForSelectedFolder() async {
        guard let path = selectedFolderPath else {
            tracksInFolder = []
            return
        }

        do {
            tracksInFolder = try await trackRepository.fetchTracks(folderPrefix: path + "/")
            applyTrackSort()
        } catch {
            tracksInFolder = []
            errorMessage = error.localizedDescription
        }
    }

    /// Refresh all data — called after imports or deletions.
    @MainActor
    func refresh() async {
        await loadRootFolders()
        if selectedFolderPath != nil {
            await loadTracksForSelectedFolder()
        }
    }

    // MARK: - Filtering

    /// Filter root nodes by search query.
    private func applyFilter() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()

        if query.isEmpty {
            rootNodes = allRootNodes
        } else {
            rootNodes = allRootNodes.filter { node in
                node.name.lowercased().contains(query)
            }
        }
    }

    // MARK: - Sorting

    /// Sort the tracks in the current folder.
    private func applyTrackSort() {
        tracksInFolder.sort { a, b in
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

    /// Compare two optional Int values for sorting.
    private func compare(_ a: Int?, _ b: Int?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _):   return .orderedAscending
        case (_, nil):   return .orderedDescending
        case let (a?, b?):
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            return .orderedSame
        }
    }

    // MARK: - Actions

    /// Reveal the selected folder in Finder.
    func revealInFinder(libraryRoot: String) {
        guard let path = selectedFolderPath else { return }
        let fullPath = URL(fileURLWithPath: libraryRoot)
            .appendingPathComponent(path)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: fullPath.path)
    }
}
