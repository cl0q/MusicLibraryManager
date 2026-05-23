import AppKit
import Foundation

// MARK: - ViewModel

/// ViewModel for the Folder Browser.
///
/// Drives a disk-based folder tree: the displayed hierarchy mirrors the actual
/// filesystem under the library root, not the artist/album metadata from the DB.
@Observable
final class FolderViewModel {

    // MARK: - Published state

    private(set) var rootNodes: [DiskFolderNode] = []
    private(set) var allRootNodes: [DiskFolderNode] = []
    private(set) var tracksInFolder: [Track] = []
    private(set) var libraryRootURL: URL?
    private(set) var isDriveNotMounted = false

    private(set) var searchResults: [DiskFolderNode] = []
    private(set) var isSearching = false
    private var searchTask: Task<Void, Never>? = nil
    private(set) var loadingNodePaths = Set<String>()

    var selectedFolderPath: String? = nil {
        didSet {
            if oldValue != selectedFolderPath {
                if let path = selectedFolderPath {
                    Task {
                        await ensureAncestorsLoaded(for: path)
                        await loadTracksForSelectedFolder()
                        
                        await MainActor.run {
                            if let node = findNode(for: path) {
                                let hasPlaceholder = node.children.contains { $0.id.hasSuffix("/__placeholder__") }
                                if hasPlaceholder {
                                    loadChildren(for: path)
                                }
                            }
                        }
                    }
                } else {
                    Task { await loadTracksForSelectedFolder() }
                }
            }
        }
    }

    var searchQuery: String = "" {
        didSet {
            applyFilter()
            triggerDiskSearch()
        }
    }

    var sortDescriptor = TrackSortDescriptor(column: .title, ascending: true) {
        didSet { applyTrackSort() }
    }

    var selectedTrackIDs: Set<Int64> = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Number of top-level folders in the tree (for display in toolbar).
    var folderCount: Int { allRootNodes.count }

    // MARK: - Dependencies

    private let trackRepository: TrackRepository
    private let configRepository: ConfigRepository
    private let diskScanner = DiskFolderScanner()

    // MARK: - Init

    init(trackRepository: TrackRepository, configRepository: ConfigRepository) {
        self.trackRepository = trackRepository
        self.configRepository = configRepository
    }

    // MARK: - Load tree

    @MainActor
    func loadRootFolders() async {
        isLoading = true
        errorMessage = nil
        isDriveNotMounted = false

        do {
            guard let rootPath = try await configRepository.getLibraryRoot(), !rootPath.isEmpty else {
                allRootNodes = []
                applyFilter()
                isLoading = false
                return
            }

            let rootURL = URL(fileURLWithPath: rootPath)

            guard FileManager.default.fileExists(atPath: rootURL.path) else {
                isDriveNotMounted = true
                allRootNodes = []
                applyFilter()
                isLoading = false
                return
            }

            libraryRootURL = rootURL

            let nodes = try await diskScanner.scan(rootURL: rootURL, recursive: false)
            allRootNodes = nodes
            applyFilter()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
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
            let dirURL = URL(fileURLWithPath: path)
            let fileURLs = try await diskScanner.filesInDirectory(dirURL)
            let paths = fileURLs.map { $0.standardizedFileURL.path }
            let result = try await trackRepository.fetchTracksByOriginalPaths(paths)
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

    // MARK: - Helpers

    /// Returns the path relative to the library root (for breadcrumb display).
    func relativePath(for fullPath: String) -> String {
        guard let root = libraryRootURL?.path else { return fullPath }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard fullPath.hasPrefix(prefix) else { return (fullPath as NSString).lastPathComponent }
        return String(fullPath.dropFirst(prefix.count))
    }

    /// Open the currently selected folder in Finder.
    func revealInFinder() {
        guard let path = selectedFolderPath else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    // MARK: - Filtering and Lazy Loading

    /// Ensures that all ancestor directories of the given path are loaded in `allRootNodes`.
    @MainActor
    func ensureAncestorsLoaded(for path: String) async {
        guard let rootPath = libraryRootURL?.path else { return }
        var current = (path as NSString).deletingLastPathComponent
        var ancestorsToLoad: [String] = []
        
        while current.hasPrefix(rootPath) && current != rootPath {
            ancestorsToLoad.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        
        // Load them from root-most to leaf-most
        for ancestor in ancestorsToLoad.reversed() {
            if let node = findNode(for: ancestor) {
                let hasPlaceholder = node.children.contains { $0.id.hasSuffix("/__placeholder__") }
                if hasPlaceholder || node.children.isEmpty {
                    do {
                        let url = URL(fileURLWithPath: ancestor)
                        let subnodes = try await diskScanner.scanSubdirectories(at: url)
                        self.allRootNodes = self.updateNodeChildren(in: self.allRootNodes, targetPath: ancestor, newChildren: subnodes)
                    } catch {
                        AppLogger.shared.error("Failed to load ancestor \(ancestor): \(error.localizedDescription)", source: "folders")
                    }
                }
            }
        }
        
        applyFilter()
    }

    /// Asynchronously scan the subdirectories of a given directory path and replace the placeholder node.
    @MainActor
    func loadChildren(for path: String) {
        guard !loadingNodePaths.contains(path) else { return }
        loadingNodePaths.insert(path)
        
        Task {
            do {
                let url = URL(fileURLWithPath: path)
                let subnodes = try await diskScanner.scanSubdirectories(at: url)
                
                await MainActor.run {
                    self.allRootNodes = self.updateNodeChildren(in: self.allRootNodes, targetPath: path, newChildren: subnodes)
                    self.applyFilter()
                    self.loadingNodePaths.remove(path)
                }
            } catch {
                await MainActor.run {
                    self.loadingNodePaths.remove(path)
                }
                AppLogger.shared.error("Failed to load children for \(path): \(error.localizedDescription)", source: "folders")
            }
        }
    }

    private func updateNodeChildren(in nodes: [DiskFolderNode], targetPath: String, newChildren: [DiskFolderNode]) -> [DiskFolderNode] {
        return nodes.map { node in
            if node.id == targetPath {
                return DiskFolderNode(id: node.id, name: node.name, children: newChildren)
            } else if !node.children.isEmpty {
                return DiskFolderNode(
                    id: node.id,
                    name: node.name,
                    children: updateNodeChildren(in: node.children, targetPath: targetPath, newChildren: newChildren)
                )
            } else {
                return node
            }
        }
    }

    /// Trigger a background, debounced recursive filesystem search for matching folders.
    private func triggerDiskSearch() {
        searchTask?.cancel()
        
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            applyFilter()
            return
        }
        
        isSearching = true
        
        searchTask = Task { [weak self] in
            guard let self = self else { return }
            
            // 200ms debounce to avoid spamming disk reads during typing
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            
            guard let rootURL = self.libraryRootURL else {
                await MainActor.run {
                    self.searchResults = []
                    self.isSearching = false
                    self.applyFilter()
                }
                return
            }
            
            do {
                let matches = try await self.diskScanner.searchDirectories(under: rootURL, query: query)
                if Task.isCancelled { return }
                
                await MainActor.run {
                    self.searchResults = matches
                    self.isSearching = false
                    self.applyFilter()
                }
            } catch {
                await MainActor.run {
                    self.searchResults = []
                    self.isSearching = false
                    self.applyFilter()
                }
            }
        }
    }

    private func applyFilter() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            rootNodes = allRootNodes
        } else {
            // Build the filtered tree from the search results paths
            let paths = searchResults.map { $0.id }
            rootNodes = buildTreeFromPaths(paths)
        }
    }

    /// Reconstruct the parent directory tree for matched search paths so that they can be displayed in the sidebar tree.
    func buildTreeFromPaths(_ paths: [String]) -> [DiskFolderNode] {
        guard let rootPath = libraryRootURL?.path else { return [] }
        
        var allPaths = Set<String>()
        for path in paths {
            var current = path
            while current.hasPrefix(rootPath) && current != rootPath {
                allPaths.insert(current)
                current = (current as NSString).deletingLastPathComponent
            }
        }
        
        return buildSubtree(at: rootPath, allPaths: allPaths)
    }

    private func buildSubtree(at path: String, allPaths: Set<String>) -> [DiskFolderNode] {
        let pathPrefix = path.hasSuffix("/") ? path : path + "/"
        let childrenPaths = allPaths.filter { p in
            guard p.hasPrefix(pathPrefix) && p != path else { return false }
            let relative = p.dropFirst(pathPrefix.count)
            return !relative.contains("/")
        }
        
        var nodes: [DiskFolderNode] = []
        for childPath in childrenPaths {
            let childURL = URL(fileURLWithPath: childPath)
            let name = childURL.lastPathComponent
            
            // Recursively build children
            let childNodes = buildSubtree(at: childPath, allPaths: allPaths)
            
            nodes.append(DiskFolderNode(
                id: childPath,
                name: name,
                children: childNodes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            ))
        }
        
        return nodes.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Recursively find a node with a matching path in the root nodes.
    func findNode(for path: String) -> DiskFolderNode? {
        return findNode(for: path, in: allRootNodes)
    }

    private func findNode(for path: String, in nodes: [DiskFolderNode]) -> DiskFolderNode? {
        for node in nodes {
            if node.id == path {
                return node
            }
            if let found = findNode(for: path, in: node.children) {
                return found
            }
        }
        return nil
    }

    /// Recursively search all folders in the library and return a flat list of matches.
    func searchMatchingFolders(query: String) -> [DiskFolderNode] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return [] }
        return findMatchingNodes(in: allRootNodes, query: trimmed)
    }

    private func findMatchingNodes(in nodes: [DiskFolderNode], query: String) -> [DiskFolderNode] {
        var results: [DiskFolderNode] = []
        for node in nodes {
            if node.name.lowercased().contains(query) {
                results.append(node)
            }
            results.append(contentsOf: findMatchingNodes(in: node.children, query: query))
        }
        return results
    }

    // MARK: - Sorting

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
            case .danceability: result = compare(a.danceability, b.danceability)
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

    private func compare(_ a: Double?, _ b: Double?) -> ComparisonResult {
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
}
