import SwiftUI

// MARK: - Columns (UC-TABLE-02/03, DEC-012)

/// Every column a track table can show. Order of the cases = order in the table (the
/// mockup's `COLS`): `#` first in containers with an own order, then Title … Status.
enum TrackColumnID: String, CaseIterable, Codable, Sendable, Identifiable {
    case number, title, artist, album, time, bpm, energy, dance, genre, year, format, kbps, added, status
    /// Context columns: only the lists that ask for them have them (never in `standardColumns`).
    /// `Match` = how close a suggestion sounds (`93 %`, V-GENRED.N10); `suggestion` = the
    /// row's state and verdicts (`Add to Genre` · `Not Now` / `Staged` · `Remove`, W3-GEN).
    case match, suggestion
    /// Review's comparison (W3-REV, V-REV.E07): `version` = the radio pick and the version's words
    /// (`Recommended — highest quality`), `location` = the file's folder, `usedIn` = playlists
    /// using it (`‹n› playlists`). Never in `standardColumns`.
    case version, location, usedIn
    /// Discover ▸ Recommendations (W3-DISC-A, V-INBOX.E06e): where the suggestion came from — a
    /// word with the 6 pt brand dot. Never in `standardColumns`; `Match` (`92 %`) is the one above.
    case source

    var id: String { rawValue }

    /// The columns of an ordinary track list (no `#`, no context columns), in table order.
    static let standardColumns: [TrackColumnID] = [
        .title, .artist, .album, .time, .bpm, .energy, .dance, .genre, .year, .format, .kbps, .added, .status,
    ]

    /// Column header (UC-TABLE-02).
    var title: String {
        switch self {
        case .number: "#"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .time: "Time"
        case .bpm: "BPM"
        case .energy: "Energy"
        case .dance: "Dance"
        case .genre: "Genre"
        case .year: "Year"
        case .format: "Format"
        case .kbps: "kbps"
        case .added: "Added"
        case .status: "Status"
        case .match: "Match"
        case .suggestion: ""
        case .version: "Version"
        case .location: "Location"
        case .usedIn: "Used in"
        case .source: "Source"
        }
    }

    /// The nine default columns (DEC-012).
    static let defaultColumns: [TrackColumnID] = [.title, .artist, .album, .time, .bpm, .energy, .genre, .added, .status]
    /// Off by default, shown through the header menu / View ▸ Columns.
    static let optionalColumns: [TrackColumnID] = [.dance, .year, .format, .kbps]
    /// The header menu and View ▸ Columns list, in this order (UC-TABLE-03). Title and `#`
    /// can't be hidden.
    static let hideableColumns: [TrackColumnID] = [
        .artist, .album, .time, .bpm, .energy, .dance, .genre, .year, .format, .kbps, .added, .status,
    ]

    var isHideable: Bool { Self.hideableColumns.contains(self) }
    var isVisibleByDefault: Bool { !Self.optionalColumns.contains(self) }

    /// Numbers right-align and use monospaced digits (UC-TYPE-03).
    var isNumeric: Bool {
        switch self {
        case .number, .time, .bpm, .year, .kbps, .match: true
        default: false
        }
    }

    /// Widths from the mockup's column set (`app.js` COLS); Title takes the rest.
    var width: (min: CGFloat?, ideal: CGFloat?, max: CGFloat?) {
        switch self {
        case .number: (32, 38, 56)
        case .title: (160, 280, nil)
        case .artist: (80, 150, nil)
        case .album: (80, 160, nil)
        case .time: (44, 52, 72)
        case .bpm: (40, 48, 64)
        case .energy: (56, 70, 96)
        case .dance: (56, 70, 96)
        case .genre: (60, 100, nil)
        case .year: (40, 48, 64)
        case .format: (44, 58, 90)
        case .kbps: (40, 50, 72)
        case .added: (72, 104, 160)
        case .status: (90, 146, 220)
        case .match: (52, 64, 80)
        case .suggestion: (170, 210, 260)
        case .version: (190, 250, 340)
        case .location: (140, 260, nil)
        case .usedIn: (70, 90, 140)
        case .source: (80, 104, 140)
        }
    }
}

// MARK: - Sort order (UC-TABLE-04)

/// A table's sort: a column and a direction; `nil` = the container's own order (playlist,
/// queue) or, without one, the order the rows were loaded in. Persisted per view as its
/// `rawValue` (`@SceneStorage`).
struct TrackSortOrder: Equatable, Hashable, Codable, Sendable, RawRepresentable {
    var column: TrackColumnID
    var ascending: Bool

    init(column: TrackColumnID, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }

    /// `title:asc`, `added:desc`.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":")
        guard parts.count == 2, let column = TrackColumnID(rawValue: String(parts[0])) else { return nil }
        switch parts[1] {
        case "asc": self.init(column: column, ascending: true)
        case "desc": self.init(column: column, ascending: false)
        default: return nil
        }
    }

    var rawValue: String { "\(column.rawValue):\(ascending ? "asc" : "desc")" }

    /// `#` ascending is the container's own order (UC-TABLE-05).
    var isContainerOrder: Bool { column == .number && ascending }

    /// The comparator the table header shows for this order.
    var comparator: KeyPathComparator<TrackRow> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch column {
        case .number: return KeyPathComparator(\TrackRow.position, order: order)
        case .title: return KeyPathComparator(\TrackRow.titleSortKey, order: order)
        case .artist: return KeyPathComparator(\TrackRow.artistSortKey, order: order)
        case .album: return KeyPathComparator(\TrackRow.albumSortKey, order: order)
        case .time: return KeyPathComparator(\TrackRow.durationSortKey, order: order)
        case .bpm: return KeyPathComparator(\TrackRow.bpmSortKey, order: order)
        case .energy: return KeyPathComparator(\TrackRow.energySortKey, order: order)
        case .dance: return KeyPathComparator(\TrackRow.danceSortKey, order: order)
        case .genre: return KeyPathComparator(\TrackRow.genreSortKey, order: order)
        case .year: return KeyPathComparator(\TrackRow.yearSortKey, order: order)
        case .format: return KeyPathComparator(\TrackRow.formatSortKey, order: order)
        case .kbps: return KeyPathComparator(\TrackRow.bitrateSortKey, order: order)
        case .added: return KeyPathComparator(\TrackRow.addedSortKey, order: order)
        case .status: return KeyPathComparator(\TrackRow.statusSortKey, order: order)
        case .match: return KeyPathComparator(\TrackRow.matchSortKey, order: order)
        case .suggestion: return KeyPathComparator(\TrackRow.suggestionSortKey, order: order)
        case .version: return KeyPathComparator(\TrackRow.versionSortKey, order: order)
        case .location: return KeyPathComparator(\TrackRow.locationSortKey, order: order)
        case .usedIn: return KeyPathComparator(\TrackRow.usedInSortKey, order: order)
        case .source: return KeyPathComparator(\TrackRow.sourceSortKey, order: order)
        }
    }

    /// The order a header click asked for (`nil` for an unknown key path).
    init?(_ comparator: KeyPathComparator<TrackRow>) {
        guard let column = TrackColumnID.allCases.first(where: { $0.sortKeyPath == comparator.keyPath }) else { return nil }
        self.init(column: column, ascending: comparator.order == .forward)
    }
}

extension TrackColumnID {
    /// The key path a column sorts by — what the table header compares to show its sort
    /// indicator. The actual sorting is `TrackRowSorter` (nil values last, ties in the
    /// container's order, keys folded once per sort).
    var sortKeyPath: PartialKeyPath<TrackRow> {
        switch self {
        case .number: \TrackRow.position
        case .title: \TrackRow.titleSortKey
        case .artist: \TrackRow.artistSortKey
        case .album: \TrackRow.albumSortKey
        case .time: \TrackRow.durationSortKey
        case .bpm: \TrackRow.bpmSortKey
        case .energy: \TrackRow.energySortKey
        case .dance: \TrackRow.danceSortKey
        case .genre: \TrackRow.genreSortKey
        case .year: \TrackRow.yearSortKey
        case .format: \TrackRow.formatSortKey
        case .kbps: \TrackRow.bitrateSortKey
        case .added: \TrackRow.addedSortKey
        case .status: \TrackRow.statusSortKey
        case .match: \TrackRow.matchSortKey
        case .suggestion: \TrackRow.suggestionSortKey
        case .version: \TrackRow.versionSortKey
        case .location: \TrackRow.locationSortKey
        case .usedIn: \TrackRow.usedInSortKey
        case .source: \TrackRow.sourceSortKey
        }
    }
}
