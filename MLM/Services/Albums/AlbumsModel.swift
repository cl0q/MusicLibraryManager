import Foundation
import Observation

/// The Albums grid's data (V-ALB, W4-2): every listed album (IMP-069) in the chosen order, the
/// scope counts that follow the in-place filter (UC-SCOPE-02), the number of tracks that have no
/// album (the footer, IMP-070) and the facts the menus need without asking the database (what
/// `Download ‹n› Missing` fetches, the first track's artwork). One read per reload; the grid
/// filters and re-sorts in memory.
///
/// First load shows placeholders (`phase == .loading`); later reloads replace the data in place.
@MainActor
@Observable
final class AlbumsModel {
    enum Phase: Equatable { case loading, loaded, failed }

    private(set) var phase = Phase.loading
    /// Every listed album, in `sort` order.
    private(set) var all: [AlbumListing] = []
    /// Listed tracks that have no album (`is: no album`).
    private(set) var noAlbumCount = 0
    /// Per album: tracks without a file that aren't downloading.
    private(set) var downloadable: [Int64: Int] = [:]
    /// Per album: its first listed track (the cover's artwork fallback).
    private(set) var firstTracks: [Int64: Int64] = [:]
    private(set) var sort: AlbumSort

    @ObservationIgnored private let albums: AlbumRepository?
    @ObservationIgnored private let scopeQueries: TrackScopeQueries?

    init(albums: AlbumRepository?, scopeQueries: TrackScopeQueries?, sort: AlbumSort = .artist) {
        self.albums = albums
        self.scopeQueries = scopeQueries
        self.sort = sort
    }

    /// A model that shows `listings` at once (snapshot fixtures, tests).
    init(preloaded listings: [AlbumListing], noAlbumCount: Int = 0, sort: AlbumSort = .artist) {
        albums = nil
        scopeQueries = nil
        self.sort = sort
        all = AlbumRepository.sorted(listings, by: sort)
        self.noAlbumCount = noAlbumCount
        phase = .loaded
    }

    // MARK: Loading

    /// Reads everything again. A failure keeps what is shown and says so (`phase == .failed`
    /// only while nothing has loaded yet).
    func reload() async {
        guard let albums else {
            if phase == .loading { phase = .failed }
            return
        }
        do {
            let listings = try await albums.fetchListed(scope: .all, sort: sort, filter: .empty)
            async let missing = albums.downloadableCounts()
            async let firsts = albums.firstTrackIDs()
            async let noAlbum = scopeQueries?.noAlbumCount()
            all = listings
            downloadable = try await missing
            firstTracks = try await firsts
            noAlbumCount = try await noAlbum ?? 0
            phase = .loaded
        } catch {
            AppLogger.shared.error("The albums couldn’t load: \(error)", source: "Albums")
            if all.isEmpty { phase = .failed }
        }
    }

    func setSort(_ newSort: AlbumSort) {
        guard newSort != sort else { return }
        sort = newSort
        all = AlbumRepository.sorted(all, by: newSort)
    }

    // MARK: Derived (pure over what was loaded)

    /// The albums that pass the in-place filter, in order.
    func filtered(_ filter: SearchFilter) -> [AlbumListing] {
        filter.isEmpty ? all : all.filter { AlbumFilterRules.matches($0, filter) }
    }

    /// The scope bar's counts for the same filter.
    func counts(filter: SearchFilter) -> [AlbumScope: Int] {
        let shown = filtered(filter)
        return Dictionary(uniqueKeysWithValues: AlbumScope.allCases.map { scope in
            (scope, scope == .all ? shown.count : shown.filter { scope.contains($0) }.count)
        })
    }

    func shown(scope: AlbumScope, filter: SearchFilter) -> [AlbumListing] {
        let base = filtered(filter)
        return scope == .all ? base : base.filter { scope.contains($0) }
    }

    func cover(for listing: AlbumListing) -> AlbumCoverRequest {
        AlbumCoverRequest(albumID: listing.id, coverPath: listing.album.coverPath, firstTrackID: firstTracks[listing.id])
    }

    /// `Download ‹n› Missing` for the albums: their tracks that have no file and aren't running.
    func missingCount(_ albumIDs: [Int64]) -> Int {
        albumIDs.reduce(0) { $0 + (downloadable[$1] ?? 0) }
    }
}
