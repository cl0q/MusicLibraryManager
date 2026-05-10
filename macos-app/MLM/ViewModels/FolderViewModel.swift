import AppKit
import Foundation

// MARK: - Folder tree node

/// A node in the folder tree hierarchy.
///
/// Built in a single pass from all `organized_path` values. Children are
/// pre-populated by `buildTree(from:)` — no lazy-loading needed.
@Observable
final class FolderNode: Identifiable, Hashable {
    let id: String       // Full path, e.g. "Artist/Album"
    let name: String     // Display name, e.g. "Album"
    var children: [FolderNode]?  // nil = legacy unloaded; [] = leaf; [...] = has children
    var trackCount: Int = 0

    var isLoaded: Bool { children != nil }

    init(id: String, name: String, children: [FolderNode]? = nil, trackCount: Int = 0) {
        self.id = id
        self.name = name
        self.children = children
        self.trackCount = trackCount
    }

    static func == (lhs: FolderNode, rhs: FolderNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - ViewModel

/// ViewModel for the Folder Browser.
///
/// Loads the full tree in a single SQL query, then filters in-memory.
/// No per-node SQL queries on expand.
@Observable
final class FolderViewModel {
    // MARK: - Published state

    private(set) var rootNodes: [FolderNode] = []
    private(set) var allRootNodes: [FolderNode] = []
    private(set) var tracksInFolder: [Track] = []

    var selectedFolderPath: String? = nil {
        didSet {
            if oldValue != selectedFolderPath {
                Task { await loadTracksForSelectedFolder() }
            }
        }
    }

    var searchQuery: String = "" {
        didSet { applyFilter() }
    }

    var sortDescriptor = TrackSortDescriptor(column: .title, ascending: true) {
        didSet { applyTrackSort() }
    }

    var selectedTrackIDs: Set<Int64> = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var totalTrackCount: Int = 0

    var artistCount: Int { allRootNodes.count }

    // MARK: - Dependencies

    private let trackRepository: TrackRepository

    // MARK: - Init

    init(trackRepository: TrackRepository) {
        self.trackRepository = trackRepository
    }

    // MARK: - Load tree (single-pass)

    @MainActor
    func loadRootFolders() async {
        isLoading = true
        errorMessage = nil

        do {
            let start = Date()
            let allPaths = try await trackRepository.fetchAllOrganizedPaths()
            totalTrackCount = allPaths.count

            let roots = buildTree(from: allPaths)
            let ms = Int(Date().timeIntervalSince(start) * 1000)

            allRootNodes = roots
            applyFilter()

            AppLogger.shared.info(
                "folder tree build: \(roots.count) artists, \(allPaths.count) tracks in \(ms)ms",
                source: "perf"
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Build the full folder tree from raw organized_path strings in one pass.
    private func buildTree(from paths: [String]) -> [FolderNode] {
        // Count tracks per immediate parent directory.
        var folderCounts: [String: Int] = [:]
        for path in paths {
            let comps = path.split(separator: "/", omittingEmptySubsequences: true)
            guard comps.count >= 2 else { continue }
            let dir = comps.dropLast().joined(separator: "/")
            folderCounts[dir, default: 0] += 1
        }

        // Collect all ancestor paths at every depth level.
        var allDirs = Set<String>()
        for dir in folderCounts.keys {
            var parts = dir.split(separator: "/")
            while !parts.isEmpty {
                allDirs.insert(parts.joined(separator: "/"))
                parts.removeLast()
            }
        }

        guard !allDirs.isEmpty else { return [] }

        // Create nodes (sorted so parents always precede their children).
        var nodeDict: [String: FolderNode] = [:]
        for dir in allDirs.sorted() {
            let parts = dir.split(separator: "/")
            let name  = String(parts.last!)
            let count = folderCounts[dir] ?? 0
            nodeDict[dir] = FolderNode(id: dir, name: name, children: [], trackCount: count)
        }

        // Wire parent → child relationships.
        for dir in allDirs.sorted() {
            let parts = dir.split(separator: "/")
            guard parts.count > 1 else { continue }
            let parentPath = parts.dropLast().joined(separator: "/")
            if let child = nodeDict[dir] {
                nodeDict[parentPath]?.children?.append(child)
            }
        }

        // Sort children alphabetically at every level.
        for node in nodeDict.values {
            node.children?.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        // Return only root-level nodes.
        return allDirs
            .filter { !$0.contains("/") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { nodeDict[$0] }
    }

    /// No-op: children are pre-populated by buildTree.
    @MainActor
    func loadChildren(for node: FolderNode) async {
        _ = node  // tree is already fully built
    }

    // MARK: - Track loading

    @MainActor
    private func loadTracksForSelectedFolder() async {
        guard let path = selectedFolderPath else {
            tracksInFolder = []
            return
        }

        let start = Date()
        do {
            let result = try await trackRepository.fetchTracksInFolder(path: path)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            tracksInFolder = result
            AppLogger.shared.info(
                "folder tracks load: \(result.count) tracks in \(ms)ms",
                source: "perf"
            )
            applyTrackSort()
        } catch {
            tracksInFolder = []
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func refresh() async {
        await loadRootFolders()
        if selectedFolderPath != nil {
            await loadTracksForSelectedFolder()
        }
    }

    // MARK: - Filtering

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

    // MARK: - Sorting (in-memory, folder tracks are small sets)

    private func applyTrackSort() {
        tracksInFolder.sort { a, b in
            let result: ComparisonResult
            switch sortDescriptor.column {
            case .title:     result = a.title.localizedCaseInsensitiveCompare(b.title)
            case .artist:    result = a.artist.localizedCaseInsensitiveCompare(b.artist)
            case .album:     result = a.album.localizedCaseInsensitiveCompare(b.album)
            case .format:    result = a.format.localizedCaseInsensitiveCompare(b.format)
            case .bitrate:   result = compare(a.bitrate, b.bitrate)
            case .duration:  result = compare(a.duration, b.duration)
            case .genre:     result = (a.genre ?? "").localizedCaseInsensitiveCompare(b.genre ?? "")
            case .year:      result = compare(a.year, b.year)
            case .energy:    result = compare(a.energyBucket, b.energyBucket)
            case .dateAdded: result = (a.dateAdded ?? "").compare(b.dateAdded ?? "")
            }
            return sortDescriptor.ascending
                ? result == .orderedAscending
                : result == .orderedDescending
        }
    }

    private func compare(_ a: Int?, _ b: Int?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil):    return .orderedSame
        case (nil, _):      return .orderedAscending
        case (_, nil):      return .orderedDescending
        case let (a?, b?):
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            return .orderedSame
        }
    }

    // MARK: - Actions

    func revealInFinder(libraryRoot: String) {
        guard let path = selectedFolderPath else { return }
        let fullPath = URL(fileURLWithPath: libraryRoot).appendingPathComponent(path)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: fullPath.path)
    }
}
