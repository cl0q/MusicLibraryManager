import Foundation
import Observation

/// One edition of an album as the page lists it (the picker and the Other versions shelf).
struct AlbumEditionInfo: Identifiable, Equatable, Sendable {
    let album: Album
    let stat: AlbumEditionStat
    /// The user's preferred edition (`user_album_variant_pref`).
    let isPreferred: Bool

    var id: Int64 { album.id ?? 0 }
    var name: String { AlbumText.editionName(album) }
    var line: String { AlbumText.editionLine(name: name, year: album.year, inLibrary: stat.inLibrary, total: stat.total) }
}

/// An album page's data (V-ALBD, W4-2): the album shown (an edition of the one opened), its
/// members in the album's own order, the rows with their `Not in library` positions and disc
/// headings (IMP-076), the facts and status lines, the editions — and Edit Order's working copy
/// (IMP-081).
///
/// Loads from the repositories; a model built with `preloaded(...)` shows fixed content
/// (snapshot fixtures, tests).
@MainActor
@Observable
final class AlbumDetailModel {
    enum Phase: Equatable { case loading, loaded, missing, failed }

    let routeID: Int64
    private(set) var phase = Phase.loading
    /// The edition shown.
    private(set) var album: Album?
    private(set) var members: [AlbumMember] = []
    private(set) var summary: AlbumSummary?
    private(set) var layout: AlbumLayout?
    private(set) var editions: [AlbumEditionInfo] = []
    /// The edition the user picked on this page, until the page closes.
    private(set) var viewedID: Int64?
    /// What the in-place filter leaves of the rows (the filter text itself).
    var filter = SearchFilter.empty
    /// The table's rows.
    let list = TrackListModel(sortOrder: TrackSortOrder(column: .number, ascending: true))
    /// Edit Order's working copy; nil while the order isn't being edited.
    private(set) var editor: AlbumOrderEditor?

    @ObservationIgnored private let albums: AlbumRepository?
    @ObservationIgnored private var isPreloaded = false

    init(albumID: Int64, albums: AlbumRepository?) {
        routeID = albumID
        self.albums = albums
    }

    /// A page that shows given content without a database.
    static func preloaded(album: Album, members: [AlbumMember], editions: [AlbumEditionInfo] = []) async -> AlbumDetailModel {
        let model = AlbumDetailModel(albumID: album.id ?? 0, albums: nil)
        model.isPreloaded = true
        model.album = album
        model.members = members
        model.editions = editions
        model.summary = AlbumDetailModel.summary(of: album, members: members)
        model.phase = .loaded
        await model.rebuildRows()
        return model
    }

    var isEditingOrder: Bool { editor != nil }
    var isCompilation: Bool {
        guard let album else { return false }
        return album.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Various Artists") == .orderedSame
            || Set(members.map { $0.track.artist.lowercased() }).count >= 3
    }

    // MARK: Loading

    func load() async {
        guard !isPreloaded else { return }
        guard let albums else {
            phase = .failed
            return
        }
        do {
            guard let requested = try await albums.fetch(id: routeID) else {
                phase = .missing
                return
            }
            let siblings = try await albums.fetchSiblings(albumId: routeID)
            let baseID = requested.variantOf ?? requested.id ?? routeID
            let preferred = try await albums.fetchVariantPref(baseAlbumId: baseID)
            let shownID = Self.editionToShow(requested: requested, siblings: siblings, viewed: viewedID, preferred: preferred)
            guard let shown = siblings.first(where: { $0.id == shownID }) ?? (shownID == requested.id ? requested : nil) else {
                phase = .missing
                return
            }
            let loadedMembers = try await albums.members(of: shown.id ?? routeID)
            let loadedSummary = try await albums.summary(id: shown.id ?? routeID)
            var infos: [AlbumEditionInfo] = []
            if siblings.count > 1 {
                let stats = try await albums.editionStats(ids: siblings.compactMap(\.id))
                infos = siblings.compactMap { sibling in
                    guard let id = sibling.id, let stat = stats[id] else { return nil }
                    return AlbumEditionInfo(album: sibling, stat: stat, isPreferred: (preferred ?? baseID) == id)
                }
            }
            album = shown
            members = loadedMembers
            summary = loadedSummary
            editions = infos
            phase = .loaded
            AlbumNames.shared.set(shown.title, for: routeID)
            if !isEditingOrder { await rebuildRows() }
        } catch {
            AppLogger.shared.error("The album couldn’t load: \(error)", source: "Albums")
            if phase == .loading { phase = .failed }
        }
    }

    /// Which edition of the group opens: the one the user picked on this page, else the one the
    /// route names when it is an edition itself, else the preferred one, else the route's.
    static func editionToShow(requested: Album, siblings: [Album], viewed: Int64?, preferred: Int64?) -> Int64 {
        let ids = Set(siblings.compactMap(\.id))
        if let viewed, ids.contains(viewed) { return viewed }
        if requested.variantOf != nil, let id = requested.id { return id }
        if let preferred, ids.contains(preferred) { return preferred }
        return requested.id ?? 0
    }

    /// Show another edition (view only; the preference is `ShellEdits.chooseEdition`).
    func show(edition id: Int64) async {
        viewedID = id
        editor = nil
        await load()
    }

    // MARK: Facts

    /// The tracks the library has that can be fetched: no file, not downloading.
    var missingDownloads: (failed: Int, notDownloaded: Int) {
        var failed = 0
        var notDownloaded = 0
        for member in members where member.track.id != nil {
            switch member.track.availability() {
            case .failed: failed += 1
            case .notDownloaded: notDownloaded += 1
            default: break
            }
        }
        return (failed, notDownloaded)
    }

    /// The tracks `Download ‹n› Missing` fetches.
    var downloadableTracks: [Track] {
        members.map(\.track).filter { track in
            switch track.availability() {
            case .failed, .notDownloaded: true
            default: false
            }
        }
    }

    /// The line under the header; nil for a complete album with nothing to fetch.
    var statusLine: AlbumStatusLine? {
        guard !isEditingOrder, let layout else { return nil }
        let missing = missingDownloads
        return AlbumStatusLine.make(absent: layout.absent, expected: layout.expected, failed: missing.failed, notDownloaded: missing.notDownloaded)
    }

    /// `2019 · Techno · 12 tracks · 58 min` — the tracklist's size when known, else the library's.
    var factsLine: String {
        let count = layout?.expected ?? members.count
        let duration = summary?.duration ?? members.reduce(0) { $0 + max($1.track.duration ?? 0, 0) }
        return AlbumText.facts(year: album?.year ?? summary?.year, genre: summary?.genre, trackCount: count, duration: duration)
    }

    static func summary(of album: Album, members: [AlbumMember]) -> AlbumSummary {
        let genres = members.compactMap { member -> String? in
            let genre = member.track.genre?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return genre.isEmpty ? nil : genre
        }
        let years = members.compactMap(\.track.year).filter { $0 > 0 }
        return AlbumSummary(year: album.year ?? AlbumRepository.majority(years), genre: AlbumRepository.majority(genres),
                            trackCount: members.count, duration: members.reduce(0) { $0 + max($1.track.duration ?? 0, 0) })
    }

    var firstTrackID: Int64? { members.first?.track.id }

    var coverRequest: AlbumCoverRequest {
        AlbumCoverRequest(albumID: album?.id ?? routeID, coverPath: album?.coverPath, firstTrackID: firstTrackID)
    }

    /// The tracks of the album in its order (playback context): the library's, never a gap.
    var orderedTracks: [Track] { members.map(\.track) }

    // MARK: Rows

    /// Rebuilds the table from the members (or the order being edited), through the filter.
    func rebuildRows() async {
        guard let album else { return }
        if let editor {
            let layout = AlbumLayout.make(editor: editor, members: members)
            let discs = Dictionary(editor.items.map { ($0.trackID, $0.disc) }, uniquingKeysWith: { first, _ in first })
            await list.setRows(AlbumLayout.rows(layout, members: members, album: album, renumber: true, discs: discs))
            return
        }
        let filtering = !filter.isEmpty
        let layout = AlbumLayout.make(members: members, fillsGaps: !filtering)
        self.layout = AlbumLayout.make(members: members)
        var rows = AlbumLayout.rows(layout, members: members, album: album)
        if filtering {
            // Only the tracks that match; no headings or gaps to explain (the filter keeps the
            // album's own numbers).
            rows = rows.filter { $0.isTrack && filter.matches($0.track) }
        }
        await list.setRows(rows)
    }

    /// The in-place filter changed.
    func setFilter(_ newFilter: SearchFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        guard !isEditingOrder else { return }
        await rebuildRows()
    }

    // MARK: Edit Order (IMP-081)

    func beginEditingOrder() async {
        guard phase == .loaded, !members.isEmpty, !isEditingOrder else { return }
        editor = AlbumOrderEditor(members: members)
        list.selection = []
        await rebuildRows()
    }

    /// Cancel / Esc: back to the order shown before.
    func cancelEditingOrder() async {
        guard isEditingOrder else { return }
        editor = nil
        await rebuildRows()
    }

    /// Done: the order to write; the working copy goes away (the page reloads when the edit
    /// lands, `.trackMetadataDidChange`).
    func finishEditingOrder() -> [(trackID: Int64, disc: Int, number: Int)]? {
        guard let editor else { return nil }
        let numbered = editor.numbered
        self.editor = nil
        return numbered
    }

    /// Tracks dropped before display row `index`. Only members of this album move.
    func dropTracks(_ ids: [Int64], atRow index: Int) async {
        guard var working = editor else { return }
        let memberIDs = Set(working.items.map(\.trackID))
        guard working.move(ids.filter(memberIDs.contains), toRow: index) else { return }
        editor = working
        await rebuildRows()
    }

    /// ⌥↑ / ⌥↓ on the selected rows.
    func nudgeSelection(by delta: Int) async {
        guard var working = editor else { return }
        let selected = Set(list.selection.filter { $0 > 0 })
        guard !selected.isEmpty, working.nudge(selected, by: delta) else { return }
        editor = working
        await rebuildRows()
    }
}
