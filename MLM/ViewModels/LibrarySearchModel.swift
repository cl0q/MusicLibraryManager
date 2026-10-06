import Foundation
import Observation

// MARK: - The Library scope (UC-SEARCH-02, V-SEARCH.E09, N03–N07)

/// A folder under the library folder whose name matches.
struct LibraryFolderHit: Identifiable, Equatable, Sendable {
    /// Full path.
    let id: String
    let name: String
    /// Where it is: `Music ▸ Artists` (the library folder's name first).
    let location: String

    /// `location` for `path` under `root` (UC-COPY-08 `▸` for paths in prose).
    static func location(of path: String, under root: String) -> String {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let parent = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
        let rootComponents = rootURL.pathComponents
        let parentComponents = parent.pathComponents
        guard parentComponents.starts(with: rootComponents) else { return parent.path }
        let relative = parentComponents.dropFirst(rootComponents.count)
        return ([rootURL.lastPathComponent] + relative).joined(separator: " ▸ ")
    }
}

/// What the Library scope shows: sections by kind, each with its first few hits and the
/// total; a section without hits is left out (Albums arrive with W4).
struct LibrarySearchResults: Equatable, Sendable {
    var tracks: [Track] = []
    var trackTotal = 0
    var playlists: [Playlist] = []
    var playlistTotal = 0
    var folders: [LibraryFolderHit] = []
    var folderTotal = 0
    /// Albums whose title, album artist or year match (`SearchFilterCapability.albums`, IMP-091).
    var albums: [AlbumListing] = []
    var albumTotal = 0

    var isEmpty: Bool { trackTotal == 0 && albumTotal == 0 && playlistTotal == 0 && folderTotal == 0 }
}

/// Searches the whole library for the field's filter: tracks in SQL (text and tokens),
/// playlists and folders by name (text). Reads only.
@MainActor
@Observable
final class LibrarySearchModel {
    /// Rows per section before `Show All`.
    static let sectionLimit = 5

    private(set) var results: LibrarySearchResults?
    /// The filter `results` belong to.
    private(set) var searchedFilter: SearchFilter?
    /// The library didn't answer (the error state); `nil` when fine.
    private(set) var failure: String?

    /// The Tracks section's rows (the shared table).
    let tracks = TrackListModel(sortOrder: nil)

    @ObservationIgnored var trackSearch: @Sendable (SearchFilter, Int) async throws -> (tracks: [Track], total: Int) = { _, _ in ([], 0) }
    @ObservationIgnored var playlists: @MainActor () -> [Playlist] = { [] }
    @ObservationIgnored var folderSearch: @Sendable (String) async -> [LibraryFolderHit] = { _ in [] }
    /// The albums the album-applicable part of the filter matches (empty filter: none).
    @ObservationIgnored var albumSearch: @Sendable (SearchFilter) async throws -> [AlbumListing] = { _ in [] }
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init() {}

    /// Search for `filter` (a newer call cancels the older one).
    func search(_ filter: SearchFilter) {
        task?.cancel()
        guard !filter.isEmpty else {
            results = nil
            searchedFilter = filter
            failure = nil
            return
        }
        let limit = Self.sectionLimit
        let trackSearch = self.trackSearch
        let folderSearch = self.folderSearch
        let albumSearch = self.albumSearch
        let albumFilter = filter.applicable(to: .albums)
        let names = SearchFilter(text: filter.parsed.freeText)
        let playlistHits = names.freeTerms.isEmpty ? [] : playlists().filter { names.matchesName($0.name) }
        task = Task { [weak self] in
            do {
                let found = try await trackSearch(filter, limit)
                let albums = albumFilter.isEmpty ? [] : try await albumSearch(albumFilter)
                let folders = names.freeTerms.isEmpty ? [] : await folderSearch(names.parsed.freeText)
                guard !Task.isCancelled, let self else { return }
                var results = LibrarySearchResults()
                results.tracks = found.tracks
                results.trackTotal = found.total
                results.albums = Array(albums.prefix(limit))
                results.albumTotal = albums.count
                results.playlists = Array(playlistHits.prefix(limit))
                results.playlistTotal = playlistHits.count
                results.folders = Array(folders.prefix(limit))
                results.folderTotal = folders.count
                await self.tracks.setTracks(found.tracks)
                guard !Task.isCancelled else { return }
                self.results = results
                self.searchedFilter = filter
                self.failure = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.failure = error.localizedDescription
                self.searchedFilter = filter
            }
        }
    }

    /// Search again for the same filter (the library changed).
    func refresh() {
        if let searchedFilter { search(searchedFilter) }
    }
}

/// Albums for the Library scope: the listed albums (Albums grid rules) that pass the filter.
enum LibraryAlbumSearch {
    static func albums(matching filter: SearchFilter, in repository: AlbumRepository) async throws -> [AlbumListing] {
        let applicable = filter.applicable(to: .albums)
        guard !applicable.isEmpty else { return [] }
        return try await repository.fetchListed(scope: .all, sort: .artist, filter: SearchFilter(text: applicable.parsed.freeText))
            .filter { AlbumFilterRules.matches($0, applicable) }
    }
}

/// Folders under the library folder whose name contains `text` (Library scope). Only while
/// the library folder is reachable — with the drive away there are no folders to list.
enum LibraryFolderSearch {
    static func folders(matching text: String, container: DependencyContainer = .shared) async -> [LibraryFolderHit] {
        guard let config = await MainActor.run(body: { container.configRepository }),
              let root = try? await config.getLibraryRoot(), !root.isEmpty,
              FileManager.default.fileExists(atPath: root) else { return [] }
        let matches = (try? await DiskFolderScanner().searchDirectories(under: URL(fileURLWithPath: root), query: text)) ?? []
        return matches.map { LibraryFolderHit(id: $0.id, name: $0.name, location: LibraryFolderHit.location(of: $0.id, under: root)) }
    }
}
