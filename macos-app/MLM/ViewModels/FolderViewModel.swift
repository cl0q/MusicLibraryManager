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

            let nodes = try await diskScanner.scan(rootURL: rootURL)
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

    // MARK: - Filtering

    private func applyFilter() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            rootNodes = allRootNodes
        } else {
            rootNodes = allRootNodes.filter { $0.name.lowercased().contains(query) }
        }
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
}
