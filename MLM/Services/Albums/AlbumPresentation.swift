import Foundation
import Observation

// The Albums surfaces' words and rules (W4-2, V-ALB / V-ALBD) — pure, unit-tested
// (`AlbumPresentationTests`). Nothing here reads the database or the disk.

// MARK: - Words

enum AlbumText {
    static func albums(_ count: Int) -> String { StatusBarText.count(count, "album", "albums") }

    /// The third line of a card: `2019 · 12 tracks`, or — for an album whose tracklist is known
    /// and not filled — `2019 · Incomplete · 9 of 12` (V-ALB.N05/N06: in words, no badge).
    static func cardLine(_ listing: AlbumListing) -> String {
        var parts: [String] = []
        if let year = listing.album.year, year > 0 { parts.append(String(year)) }
        if listing.isIncomplete, let expected = listing.tracklist.expectedCount {
            parts.append("Incomplete · \(listing.tracklist.presentCount) of \(expected)")
        } else {
            parts.append(StatusBarText.tracks(listing.trackCount))
        }
        return parts.joined(separator: " · ")
    }

    /// Default status-bar text (UC-STATUS-02): `1,204 albums`, `12 of 1,204 albums` while filtered.
    static func statusText(shown: Int, total: Int, isFiltered: Bool) -> String {
        guard isFiltered, shown != total else { return albums(total) }
        return "\(shown.formatted(.number)) of \(albums(total))"
    }

    /// One card selected: `“Low Season” selected · 10 tracks`; several: `3 albums selected · 41 tracks`.
    static func selectedText(_ chosen: [AlbumListing]) -> String? {
        guard let first = chosen.first else { return nil }
        if chosen.count == 1 {
            return "“\(first.album.title)” selected · \(StatusBarText.tracks(first.trackCount))"
        }
        return "\(albums(chosen.count)) selected · \(StatusBarText.tracks(chosen.reduce(0) { $0 + $1.trackCount }))"
    }

    /// The footer line under the grid.
    static func noAlbumLine(_ count: Int) -> String {
        count == 1 ? "1 track has no album" : "\(count.formatted(.number)) tracks have no album"
    }

    /// The empty state's second sentence.
    static func emptyDescription(noAlbumCount: Int) -> String {
        let base = "Albums appear when tracks carry album information."
        guard noAlbumCount > 0 else { return base }
        let tracks = noAlbumCount == 1 ? "1 track in this library has" : "\(noAlbumCount.formatted(.number)) tracks in this library have"
        return "\(base) \(tracks) no album."
    }

    /// `No album matches the search and the selected scope.`
    static func filteredEmptyText(hasQuery: Bool, scope: AlbumScope) -> String {
        switch (hasQuery, scope) {
        case (true, .all): "No album matches the search."
        case (true, _): "No album matches the search and the selected scope."
        case (false, _): "No album is in “\(scope.title)”."
        }
    }

    /// `Album` / `Compilation` (V-ALBD.N03).
    static func kindLabel(isCompilation: Bool) -> String { isCompilation ? "Compilation" : "Album" }

    /// The facts line (V-ALBD.N06): `2019 · Techno · 12 tracks · 58 min`. `trackCount` counts the
    /// tracklist when it is known (IMP-076), else the library tracks.
    static func facts(year: Int?, genre: String?, trackCount: Int, duration: Int) -> String {
        var parts: [String] = []
        if let year, year > 0 { parts.append(String(year)) }
        if let genre, !genre.isEmpty { parts.append(genre) }
        parts.append(StatusBarText.tracks(trackCount))
        if duration > 0 { parts.append(TrackDurationText.total(duration)) }
        return parts.joined(separator: " · ")
    }

    /// `Disc 2 · 12 tracks · 58 min` (V-ALBD.N15).
    static func discHeading(disc: Int, tracks: Int, duration: Int) -> String {
        var text = "Disc \(disc) · \(StatusBarText.tracks(tracks))"
        if duration > 0 { text += " · \(TrackDurationText.total(duration))" }
        return text
    }

    /// `Track 5` — the label of a position nothing fills (IMP-076).
    static func absentTitle(number: Int) -> String { "Track \(number)" }

    /// Window title of the album's page and the offline line (V-ALBD.N25).
    static func playPaused(volume: String) -> String {
        "Play and Shuffle are paused — “\(volume)” is not connected."
    }

    static func editionName(_ album: Album) -> String {
        guard let kind = album.variantKind?.trimmingCharacters(in: .whitespacesAndNewlines), !kind.isEmpty else {
            return "Standard edition"
        }
        let capitalised = kind.prefix(1).uppercased() + kind.dropFirst()
        return capitalised.contains(" ") ? capitalised : "\(capitalised) edition"
    }

    /// One line of the edition picker: `Deluxe edition (2020) — 12 of 16 in library`.
    static func editionLine(name: String, year: Int?, inLibrary: Int, total: Int) -> String {
        let years = year.flatMap { $0 > 0 ? " (\($0))" : nil } ?? ""
        return "\(name)\(years) — \(inLibrary.formatted(.number)) of \(total.formatted(.number)) in library"
    }

    /// The facts of a card on the Other versions shelf: `2020 · 12 of 16 in library`.
    static func shelfLine(year: Int?, inLibrary: Int, total: Int) -> String {
        var parts: [String] = []
        if let year, year > 0 { parts.append(String(year)) }
        parts.append("\(inLibrary.formatted(.number)) of \(total.formatted(.number)) in library")
        return parts.joined(separator: " · ")
    }

    /// `“Deluxe edition (2020)” is now the preferred edition of “Low Season”`.
    static func editionChosen(edition: String, album: String) -> String {
        "“\(edition)” is now the preferred edition of “\(album)”"
    }
}

// MARK: - The status line of an album page (IMP-076, V-ALBD.N13)

struct AlbumStatusLine: Equatable, Sendable {
    let text: String
    /// Tracks the `Download ‹n› Missing` button fetches (not downloaded + failed); 0 = no button.
    let downloadCount: Int

    var downloadTitle: String { "Download \(downloadCount.formatted(.number)) Missing" }

    /// `nil` for a complete album with nothing to download (the line is hidden).
    /// - `absent`: numbering gaps of the tracklist; `expected`: the tracklist's size.
    static func make(absent: Int, expected: Int?, failed: Int, notDownloaded: Int) -> AlbumStatusLine? {
        var parts: [String] = []
        if absent > 0, let expected {
            parts.append("Incomplete · \(absent.formatted(.number)) of \(expected.formatted(.number)) not in library")
        }
        if failed > 0 {
            parts.append(absent > 0 ? "\(failed.formatted(.number)) download failed" : "Incomplete · \(failed.formatted(.number)) failed")
        }
        if notDownloaded > 0 {
            parts.append(absent > 0 || failed > 0
                ? "\(notDownloaded.formatted(.number)) not downloaded"
                : "Not downloaded · \(StatusBarText.tracks(notDownloaded))")
        }
        guard !parts.isEmpty else { return nil }
        return AlbumStatusLine(text: parts.joined(separator: " · "), downloadCount: failed + notDownloaded)
    }
}

// MARK: - Filtering the grid (UC-SEARCH-01/04)

enum AlbumFilterRules {
    /// Free words against title, album artist and year (`matchesName`); `artist:` against the
    /// album artist or artist, `album:` against the title, `year:` against the year. Kinds
    /// combine with AND, values of one kind with OR; tokens of other kinds don't apply here.
    static func matches(_ listing: AlbumListing, _ filter: SearchFilter) -> Bool {
        let album = listing.album
        guard filter.matchesName("\(album.title) \(album.albumArtist) \(album.year.map(String.init) ?? "")") else { return false }
        let grouped = Dictionary(grouping: filter.allTokens.filter { applies($0.kind) }, by: \.kind)
        for (_, tokens) in grouped where !tokens.contains(where: { matches(album, $0) }) { return false }
        return true
    }

    static func applies(_ kind: SearchTokenKind) -> Bool {
        kind == .artist || kind == .album || kind == .year
    }

    private static func matches(_ album: Album, _ token: SearchToken) -> Bool {
        switch (token.kind, token.value) {
        case (.artist, .text(let value, let exact)):
            return textMatches(album.albumArtist, value, exact) || textMatches(album.artist, value, exact)
        case (.album, .text(let value, let exact)):
            return textMatches(album.title, value, exact)
        case (.year, .range(let range)):
            return album.year.map(range.contains) ?? false
        default:
            return false
        }
    }

    private static func textMatches(_ field: String, _ value: String, _ exact: Bool) -> Bool {
        let lhs = SearchFilter.fold(field.trimmingCharacters(in: .whitespaces))
        let rhs = SearchFilter.fold(value.trimmingCharacters(in: .whitespaces))
        return exact ? lhs == rhs : lhs.contains(rhs)
    }
}

// MARK: - The album's rows (fixed order, gaps, discs)

/// A member of an album as the page shows it: the track, its disc and the number its file says.
struct AlbumMember: Equatable, Sendable {
    let track: Track
    let disc: Int
    let number: Int?
}

/// The page's rows in order: the tracks in the album's own order (disc, position), a
/// `Not in library` row for every numbering gap of a known tracklist (IMP-076) and a heading per
/// disc when there are several.
struct AlbumLayout: Equatable, Sendable {
    enum Entry: Equatable, Sendable {
        case track(Int64)
        case absent(disc: Int, number: Int)
        case header(disc: Int, tracks: Int, duration: Int)
    }

    let entries: [Entry]
    let discCount: Int
    /// The tracklist's size when it is known (sum over discs of the highest number).
    let expected: Int?
    /// Positions of the tracklist that no library track fills.
    let absent: Int

    /// - Parameter fillsGaps: show a row per numbering gap. Off while the order is edited.
    static func make(members: [AlbumMember], fillsGaps: Bool = true) -> AlbumLayout {
        let tracklist = AlbumTracklist(members.map { ($0.disc, $0.number) })
        let discs = Array(Set(members.map(\.disc))).sorted()
        var entries: [Entry] = []
        var absent = 0
        for disc in discs {
            let inDisc = members.filter { $0.disc == disc }
            var gaps: [Int] = []
            if tracklist.isKnown, fillsGaps {
                let present = Set(inDisc.compactMap(\.number))
                gaps = (1...max(present.max() ?? 1, 1)).filter { !present.contains($0) }
            }
            if discs.count > 1 {
                let duration = inDisc.reduce(0) { $0 + max($1.track.duration ?? 0, 0) }
                entries.append(.header(disc: disc, tracks: inDisc.count + gaps.count, duration: duration))
            }
            var pending = gaps[...]
            for member in inDisc {
                if let number = member.number {
                    while let gap = pending.first, gap < number {
                        entries.append(.absent(disc: disc, number: gap))
                        pending = pending.dropFirst()
                    }
                }
                entries.append(.track(member.track.id ?? 0))
            }
            for gap in pending { entries.append(.absent(disc: disc, number: gap)) }
            absent += gaps.count
        }
        return AlbumLayout(entries: entries, discCount: discs.count, expected: tracklist.expectedCount, absent: absent)
    }

    /// The layout of an order being edited: headings per disc (when several), the tracks as
    /// moved, no gap rows.
    static func make(editor: AlbumOrderEditor, members: [AlbumMember]) -> AlbumLayout {
        let durations = Dictionary(members.compactMap { member in member.track.id.map { ($0, max(member.track.duration ?? 0, 0)) } },
                                   uniquingKeysWith: { first, _ in first })
        var entries: [Entry] = []
        for row in editor.rows {
            switch row {
            case .header(let disc):
                let inDisc = editor.items.filter { $0.disc == disc }
                entries.append(.header(disc: disc, tracks: inDisc.count, duration: inDisc.reduce(0) { $0 + (durations[$1.trackID] ?? 0) }))
            case .track(let id):
                entries.append(.track(id))
            }
        }
        return AlbumLayout(entries: entries, discCount: editor.discs.count, expected: nil, absent: 0)
    }

    /// The rows for the table: real tracks with their number within the disc, synthetic rows for
    /// the gaps and the disc headings. `renumber` shows 1, 2, 3… per disc whatever the files say
    /// (Edit Order); `discs` overrides the discs of tracks that were moved there.
    static func rows(_ layout: AlbumLayout, members: [AlbumMember], album: Album, renumber: Bool = false,
                     discs: [Int64: Int]? = nil) -> [TrackRow] {
        let byID = Dictionary(members.compactMap { member in member.track.id.map { ($0, member) } }, uniquingKeysWith: { first, _ in first })
        var tracks: [Track] = []
        var kinds: [TrackRowSynthetic] = []
        var numbers: [Int?] = []
        var indexInDisc: [Int: Int] = [:]
        for entry in layout.entries {
            switch entry {
            case .track(let id):
                guard let member = byID[id] else { continue }
                let disc = discs?[id] ?? member.disc
                indexInDisc[disc, default: 0] += 1
                tracks.append(member.track)
                kinds.append(.none)
                numbers.append(renumber ? indexInDisc[disc] : (member.number ?? indexInDisc[disc]))
            case .absent(let disc, let number):
                var track = Track(artist: album.albumArtist, album: album.title, title: AlbumText.absentTitle(number: number),
                                  format: "", originalPath: "album-absent://\(album.id ?? 0)/\(disc)/\(number)")
                track.id = syntheticID(absentDisc: disc, number: number)
                tracks.append(track)
                kinds.append(.absent)
                numbers.append(number)
            case .header(let disc, let count, let duration):
                var track = Track(artist: "", album: album.title, title: AlbumText.discHeading(disc: disc, tracks: count, duration: duration),
                                  format: "", originalPath: "album-disc://\(album.id ?? 0)/\(disc)")
                track.id = syntheticID(header: disc)
                tracks.append(track)
                kinds.append(.discHeader)
                numbers.append(nil)
            }
        }
        var rows = TrackRowBuilder.build(tracks)
        for index in rows.indices {
            rows[index].synthetic = kinds[index]
            rows[index].displayNumber = numbers[index]
        }
        return rows
    }

    /// Negative ids that can't meet a library track's: a gap `disc/number`, a disc heading.
    static func syntheticID(absentDisc disc: Int, number: Int) -> Int64 { -Int64(disc * 10_000 + min(number, 9_999)) - 1 }
    static func syntheticID(header disc: Int) -> Int64 { -1_000_000_000 - Int64(disc) }
}

// MARK: - Edit Order (IMP-081)

/// The order being edited: the album's tracks with their disc, moved by drag or ⌥↑ / ⌥↓ — also
/// across discs. Done writes `numbered` (1, 2, 3… within each disc); Cancel drops it.
struct AlbumOrderEditor: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let trackID: Int64
        var disc: Int
    }

    private(set) var items: [Item]

    init(members: [AlbumMember]) {
        items = members.compactMap { member in member.track.id.map { Item(trackID: $0, disc: member.disc) } }
            .enumerated().sorted { ($0.element.disc, $0.offset) < ($1.element.disc, $1.offset) }.map(\.element)
    }

    init(items: [Item]) { self.items = items }

    /// The display rows: a heading per disc when there are several, then the disc's tracks.
    enum Row: Equatable, Sendable {
        case header(disc: Int)
        case track(Int64)
    }

    var discs: [Int] { Array(Set(items.map(\.disc))).sorted() }

    var rows: [Row] {
        let discs = self.discs
        var result: [Row] = []
        for disc in discs {
            if discs.count > 1 { result.append(.header(disc: disc)) }
            result += items.filter { $0.disc == disc }.map { .track($0.trackID) }
        }
        return result
    }

    /// Drop `moving` (in this order) before display row `index` (`rows.count` = at the end). They
    /// take the disc of the row above the line. Returns false when nothing changes.
    @discardableResult
    mutating func move(_ moving: [Int64], toRow index: Int) -> Bool {
        let movingSet = Set(moving)
        let dragged = moving.compactMap { id in items.first { $0.trackID == id } }
        guard !dragged.isEmpty else { return false }
        let display = rows
        let line = min(max(index, 0), display.count)
        // The disc above the line: the nearest row above that isn't being moved (a heading counts).
        var disc: Int?
        var above = 0
        for row in display[..<line] {
            switch row {
            case .header(let heading): disc = heading
            case .track(let id):
                if !movingSet.contains(id), let item = items.first(where: { $0.trackID == id }) {
                    disc = item.disc
                    above += 1
                }
            }
        }
        var remaining = items.filter { !movingSet.contains($0.trackID) }
        let target = disc ?? remaining.first?.disc ?? dragged[0].disc
        // Tracks above the line that stay are the ones before the insertion point; a heading
        // line at the very start of a disc puts them first on that disc.
        let insertAt = min(above, remaining.count)
        let before = items
        remaining.insert(contentsOf: dragged.map { Item(trackID: $0.trackID, disc: target) }, at: insertAt)
        items = remaining.enumerated().sorted { ($0.element.disc, $0.offset) < ($1.element.disc, $1.offset) }.map(\.element)
        return items != before
    }

    /// ⌥↑ / ⌥↓: the selected tracks one display row up or down. Returns false at the edge.
    @discardableResult
    mutating func nudge(_ selected: Set<Int64>, by delta: Int) -> Bool {
        let display = rows
        let chosen = display.enumerated().compactMap { offset, row -> (Int, Int64)? in
            if case .track(let id) = row, selected.contains(id) { return (offset, id) }
            return nil
        }
        guard let first = chosen.first?.0, let last = chosen.last?.0 else { return false }
        let line = delta < 0 ? first - 1 : last + 2
        guard line >= 0, line <= display.count, !(delta < 0 && first == 0), !(delta > 0 && last + 1 >= display.count) else { return false }
        return move(chosen.map(\.1), toRow: line)
    }

    /// What Done writes: every track with its disc and its number within the disc, in order.
    var numbered: [(trackID: Int64, disc: Int, number: Int)] {
        var counts: [Int: Int] = [:]
        return items.map { item in
            counts[item.disc, default: 0] += 1
            return (item.trackID, item.disc, counts[item.disc] ?? 1)
        }
    }
}

// MARK: - Go to Album

/// Track ▸ Go to Album and the context menu's item (UC-MENU-05, CM-TRACK, W4-2): the album page
/// of the one selected track that belongs to an album.
@MainActor
enum GoToAlbum {
    static let disabledReason = "Select one track that belongs to an album."

    /// The album of a one-track selection; `nil` otherwise.
    static func album(of selection: TrackSelection?) -> Int64? {
        guard let selection, selection.summary.count == 1, let track = selection.selectedTracks.first else { return nil }
        return track.albumId
    }
}

// MARK: - Names for the window title

/// The titles of the albums whose pages were opened, for `NavigationModel.title(names:)`
/// (UC-WIN-06): the page registers its album's name when it loads.
@MainActor
@Observable
final class AlbumNames {
    static let shared = AlbumNames()

    private(set) var names: [Int64: String] = [:]

    func name(for id: Int64) -> String? { names[id] }

    func set(_ name: String, for id: Int64) {
        guard names[id] != name else { return }
        names[id] = name
    }
}

/// Where `Find Albums` leads (Review ▸ Albums, W4-3): the tab the Review page should show next.
/// Nothing reads it before W4-3 builds the tab; the entry points are disabled until then.
@MainActor
@Observable
final class ReviewTabRequest {
    static let shared = ReviewTabRequest()
    var pending: ReviewTab?
}
