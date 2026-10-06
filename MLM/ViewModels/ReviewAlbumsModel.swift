import Foundation
import Observation

/// Review ▸ Albums (V-REV.N05–N11, DEC-021, IMP-082…086): the tracks without an album, the
/// suggestions the lookup found for them, and the decisions — each one undo step through
/// `AlbumSuggestionDecisions`. The lookup itself is `AlbumLookupRunner` (an Activity operation).
@MainActor
@Observable
final class ReviewAlbumsModel {
    struct Dependencies {
        var repository: AlbumSuggestionRepository
        var decisions: AlbumSuggestionDecisions
        /// `‹n› tracks without album`.
        var noAlbumCount: @MainActor () async -> Int
        /// `Write tags to files` (Settings ▸ Library) — the bulk alert says whether files change.
        var writesTags: @MainActor () async -> Bool

        @MainActor
        static func live(_ container: DependencyContainer = .shared) -> Dependencies? {
            guard let manager = container.databaseManager, let decisions = AlbumSuggestionDecisions.Dependencies.live(container) else { return nil }
            return Dependencies(
                repository: AlbumSuggestionRepository(database: manager.pool),
                decisions: AlbumSuggestionDecisions(dependencies: decisions),
                noAlbumCount: { (try? await TrackScopeQueries(database: manager.pool).noAlbumCount()) ?? 0 },
                writesTags: { await TagWriteSetting.isEnabled(container.configRepository) })
        }
    }

    /// `Accept All Above 90 %`: matches strictly above this.
    static let bulkThreshold: Double = 90

    let dependencies: Dependencies
    let lookup: AlbumLookupRunner

    /// The chosen filter; changing it loads that list.
    private(set) var filter: AlbumSuggestionFilter = .suggestions
    private(set) var items: [AlbumSuggestionItem] = []
    private(set) var counts = AlbumSuggestionCounts()
    /// Listed tracks without an album (not confirmed `No album`).
    private(set) var tracksWithoutAlbum = 0
    /// Pending suggestions above the bulk threshold (all of them, whatever the search shows).
    private(set) var bulkItems: [AlbumSuggestionItem] = []
    /// Track id → the album the suggestion names, where that album exists.
    private(set) var existingAlbums: [Int64: Int64] = [:]
    private(set) var isLoaded = false
    private(set) var writesTags = false
    /// The in-place filter of this view (`SearchCoordinator.filter(for: .review)`).
    var search: SearchFilter = .empty
    /// The library's disk (the bulk alert's parenthetical).
    var drive = LibraryDriveState(volumeName: nil, isConnected: true)

    init(dependencies: Dependencies, lookup: AlbumLookupRunner? = nil) {
        self.dependencies = dependencies
        self.lookup = lookup ?? .shared
    }

    // MARK: Lists

    /// The rows the search leaves.
    var visibleItems: [AlbumSuggestionItem] {
        guard !search.isEmpty else { return items }
        return items.filter { search.matchesName("\($0.track.title) \($0.track.artist) \($0.row.suggestion.albumTitle)") }
    }

    var isFiltering: Bool { !search.isEmpty }

    /// A lookup ran at some time (rows exist or a date is stored).
    var hasLookedUp: Bool { counts.rows > 0 || lookup.lastLookup != nil }

    func item(withID id: Int64) -> AlbumSuggestionItem? { items.first { $0.id == id } }

    /// The lists exactly as `reload()` would leave them — for snapshot fixtures and previews,
    /// which render the view without a database round trip.
    func preload(items: [AlbumSuggestionItem], counts: AlbumSuggestionCounts, tracksWithoutAlbum: Int,
                 filter: AlbumSuggestionFilter = .suggestions, bulkItems: [AlbumSuggestionItem] = [], writesTags: Bool = false) {
        self.items = items
        self.counts = counts
        self.tracksWithoutAlbum = tracksWithoutAlbum
        self.filter = filter
        self.bulkItems = bulkItems
        self.writesTags = writesTags
        isLoaded = true
    }

    func setFilter(_ newFilter: AlbumSuggestionFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        await reload()
    }

    func reload() async {
        let repository = dependencies.repository
        counts = (try? await repository.counts()) ?? counts
        tracksWithoutAlbum = await dependencies.noAlbumCount()
        writesTags = await dependencies.writesTags()
        let listed = (try? await repository.pending(filter: filter)) ?? []
        items = listed
        bulkItems = (try? await repository.pending(above: Self.bulkThreshold)) ?? []
        existingAlbums = (try? await repository.existingAlbumIDs(for: listed)) ?? [:]
        isLoaded = true
    }

    // MARK: Header (V-REV.N05)

    /// `6,341 tracks without album · 1,204 suggestions ready`.
    var headerLine: String {
        Self.headerLine(withoutAlbum: tracksWithoutAlbum, ready: counts.pending)
    }

    static func headerLine(withoutAlbum: Int, ready: Int) -> String {
        let tracks = withoutAlbum == 1 ? "1 track without album" : "\(withoutAlbum.formatted(.number)) tracks without album"
        let suggestions = ready == 1 ? "1 suggestion ready" : "\(ready.formatted(.number)) suggestions ready"
        return "\(tracks) · \(suggestions)"
    }

    /// `Accept All Above 90 % (812)…`
    var bulkButtonTitle: String { "Accept All Above 90 % (\(bulkItems.count.formatted(.number)))…" }

    /// The status bar: `812 suggestions` for the list shown.
    func statusText(rows: Int) -> String {
        switch filter {
        case .suggestions: rows == 1 ? "1 suggestion" : "\(rows.formatted(.number)) suggestions"
        case .noMatch: rows == 1 ? "1 track without a match" : "\(rows.formatted(.number)) tracks without a match"
        case .noAlbum: rows == 1 ? "1 track confirmed as No album" : "\(rows.formatted(.number)) tracks confirmed as No album"
        }
    }

    // MARK: Bulk alert (A-REV-ALBBULK)

    static func bulkTitle(_ count: Int) -> String {
        count == 1 ? "Set the album for 1 track?" : "Set the album for \(count.formatted(.number)) tracks?"
    }

    static func bulkButton(_ count: Int) -> String {
        count == 1 ? "Accept 1 Suggestion" : "Accept \(count.formatted(.number)) Suggestions"
    }

    /// `Every suggestion with a match above 90 % is accepted: Album, Album artist, Year and track
    /// number are set, and the changes are written to the files (queued while “Lexxar” is not
    /// connected). You can undo this in one step.` — the file clause only while `Write tags to
    /// files` is on, the parenthetical only while the drive is away.
    static func bulkMessage(writesTags: Bool, offlineVolume: String?) -> String {
        var text = "Every suggestion with a match above 90 % is accepted: Album, Album artist, Year and track number are set"
        if writesTags {
            text += ", and the changes are written to the files"
            if let offlineVolume { text += " (queued while “\(offlineVolume)” is not connected)" }
        }
        return text + ". You can undo this in one step."
    }

    var bulkMessage: String {
        Self.bulkMessage(writesTags: writesTags, offlineVolume: drive.isOffline ? drive.volumeName : nil)
    }

    // MARK: Decisions

    /// Accept the given rows (Return, the menu, the row button).
    func accept(_ ids: Set<Int64>, undo: UndoCenter) async {
        let chosen = items.filter { ids.contains($0.id) }
        await dependencies.decisions.accept(chosen, undo: undo)
        await reload()
    }

    func acceptAllAbove(undo: UndoCenter) async {
        await dependencies.decisions.accept(bulkItems, undo: undo)
        await reload()
    }

    func reject(_ ids: Set<Int64>, undo: UndoCenter) async {
        await dependencies.decisions.reject(items.filter { ids.contains($0.id) }, undo: undo)
        await reload()
    }

    func markNoAlbum(_ ids: Set<Int64>, undo: UndoCenter) async {
        await dependencies.decisions.markNoAlbum(items.filter { ids.contains($0.id) }, undo: undo)
        await reload()
    }

    func suggestAgain(_ ids: Set<Int64>, undo: UndoCenter) async {
        await dependencies.decisions.suggestAgain(items.filter { ids.contains($0.id) }, undo: undo)
        await reload()
    }

    func choose(alternativeAt index: Int, for id: Int64) async {
        guard let item = item(withID: id) else { return }
        await dependencies.decisions.choose(alternativeAt: index, for: item)
        await reload()
    }

    // MARK: Words of a row

    /// `Suggested: “Good Lies” — Folder name, 90 % match` (the year follows the title in the cell).
    static func suggestionLine(_ suggestion: AlbumSuggestion) -> String {
        "Suggested: “\(suggestion.albumTitle)” — \(suggestion.source), \(suggestion.matchPercent) % match"
    }

    /// An alternative in the pop-up: `Classics · 1995 — Folder name · 71 %`.
    static func alternativeLine(_ suggestion: AlbumSuggestion) -> String {
        let year = suggestion.year.map { " · \($0)" } ?? ""
        return "\(suggestion.albumTitle)\(year) — \(suggestion.source) · \(suggestion.matchPercent) %"
    }
}
