import Foundation

// MARK: - Row model

/// Where a row's file lives, decided once when the row is built (no disk access): a path
/// relative to the library folder, an absolute path (with its `/Volumes/<name>` if any), or
/// no file at all.
enum TrackFileLocation: Equatable, Hashable, Sendable {
    case none
    case libraryFolder
    case absolute(volumePath: String?)

    /// Whether the file sits on the disk at `volumePath` (the library's disk).
    func isOnVolume(_ volumePath: String) -> Bool {
        switch self {
        case .none: false
        case .libraryFolder: true
        case .absolute(let volume): volume == volumePath
        }
    }
}

/// One row of a track table: the track plus everything a cell shows, computed **once** when
/// the rows are built (off the main actor for big lists) — so drawing, scrolling, sorting and
/// selecting never format, parse or touch the disk (UC-TABLE-20).
struct TrackRow: Identifiable, Equatable, Sendable {
    let id: Int64
    let track: Track
    /// 1-based position in the container's own order (playlist, queue) or the load order.
    let position: Int
    /// Persisted availability (`TrackAvailability.derive`).
    let availability: TrackAvailability
    let fileLocation: TrackFileLocation

    let title: String
    /// `nil` renders `—` (UC-TABLE-11).
    let artistText: String?
    /// `nil` for no album, `unknown album` or a source name stored as album (DEC-013).
    let albumText: String?
    let genreText: String?
    let timeText: String?
    let bpmText: String?
    let yearText: String?
    let formatText: String?
    let kbpsText: String?
    let addedText: String?
    /// Sortable form of the Added date (`yyyy-MM-dd…`), empty when absent.
    let addedSortValue: String
    /// 1…5, `nil` when not analysed.
    let energyLevel: Int?
    let danceLevel: Int?
    /// `‹reason› · ‹n› attempts left` for a failed download (UC-TABLE-13, second line).
    let failureDetail: String?
    /// How close a suggested track sounds to the reference, 0…100 (`Match` column, W3-GEN);
    /// nil outside suggestion lists.
    var matchPercent: Int? = nil

    var hasFile: Bool { availability.hasFile }
}

// MARK: - Key paths the table header compares (identity only; sorting is TrackRowSorter)

extension TrackRow {
    var titleSortKey: String { title }
    var artistSortKey: String { artistText ?? "" }
    var albumSortKey: String { albumText ?? "" }
    var durationSortKey: Int { track.duration ?? -1 }
    var bpmSortKey: Int { track.bpm ?? -1 }
    var energySortKey: Int { energyLevel ?? -1 }
    var danceSortKey: Double { track.danceability ?? -1 }
    var genreSortKey: String { genreText ?? "" }
    var yearSortKey: Int { track.year ?? -1 }
    var formatSortKey: String { formatText ?? "" }
    var bitrateSortKey: Int { track.bitrate ?? -1 }
    var addedSortKey: String { addedSortValue }
    var statusSortKey: Int { availability.statusSortRank }
    var matchSortKey: Int { matchPercent ?? -1 }
    /// The suggestion column sorts like Match (best first).
    var suggestionSortKey: Double { Double(matchPercent ?? -1) }
    /// Review's comparison columns keep the versions in their own order (not sortable, W3-REV);
    /// each has its own key path so a header maps back to its column.
    var versionSortKey: Int { position }
    var locationSortKey: Int { position }
    var usedInSortKey: Int { position }
    /// Discover's source column keeps the loaded order (W3-DISC-A).
    var sourceSortKey: Int { position }
}

// MARK: - Building rows

/// Per-view inputs to row building.
struct TrackRowBuildContext: Sendable {
    /// What `Added` means (UC-TABLE-19): added to the library, or added to this container.
    enum AddedMeaning: Sendable, Equatable { case library, container }

    var addedMeaning: AddedMeaning = .library
    /// Container `added_at` per track id (playlist membership).
    var containerAddedDates: [Int64: String] = [:]
    /// `Match` per track id (suggestion lists, W3-GEN).
    var matchPercents: [Int64: Int] = [:]

    static let library = TrackRowBuildContext()
}

enum TrackRowBuilder {
    /// Rows in the given order (positions 1…n). Tracks without an id are skipped.
    static func build(_ tracks: [Track], context: TrackRowBuildContext = .library) -> [TrackRow] {
        var rows: [TrackRow] = []
        rows.reserveCapacity(tracks.count)
        var dayCache: [Substring: String] = [:]
        var position = 0
        for track in tracks {
            guard let id = track.id else { continue }
            position += 1
            rows.append(row(for: track, id: id, position: position, context: context, dayCache: &dayCache))
        }
        return rows
    }

    static func row(
        for track: Track,
        id: Int64,
        position: Int,
        context: TrackRowBuildContext,
        dayCache: inout [Substring: String]
    ) -> TrackRow {
        let availability = track.availability()
        let added: String?
        switch context.addedMeaning {
        case .library: added = nonEmpty(track.dateAddedLibrary) ?? nonEmpty(track.dateAdded)
        case .container: added = context.containerAddedDates[id] ?? nonEmpty(track.dateAdded)
        }
        let failureDetail: String?
        if case .failed(let reason, _, _) = availability {
            // Plain words for any stored reason, never the raw text (W2-B, UC-TABLE-13).
            failureDetail = DownloadFailureReasonText.detail(
                reason, failure: track.downloadFailureRecord,
                sourceHint: DownloadFailureReasonText.sourceHint(for: track))
        } else {
            failureDetail = nil
        }
        return TrackRow(
            id: id,
            track: track,
            position: position,
            availability: availability,
            fileLocation: fileLocation(track.organizedPath),
            title: track.title,
            artistText: TrackMetadataPresentation.artistDisplay(track.artist),
            albumText: TrackMetadataPresentation.albumDisplay(track.album),
            genreText: nonEmpty(track.genre),
            timeText: TrackDurationText.trackTime(track.duration),
            bpmText: track.bpm.flatMap { $0 > 0 ? String($0) : nil },
            yearText: track.year.flatMap { $0 > 0 ? String($0) : nil },
            formatText: availability.hasFile ? nonEmpty(track.format.trimmingCharacters(in: .whitespacesAndNewlines))?.uppercased() : nil,
            kbpsText: track.bitrate.flatMap { $0 > 0 ? String($0) : nil },
            addedText: added.flatMap { dayText($0, cache: &dayCache) },
            addedSortValue: added ?? "",
            energyLevel: track.energyBucket.flatMap { (1...5).contains($0) ? $0 : nil },
            danceLevel: track.danceability.map(DanceabilitySteps.scoreToLevel),
            failureDetail: failureDetail,
            matchPercent: context.matchPercents[id]
        )
    }

    static func fileLocation(_ organizedPath: String?) -> TrackFileLocation {
        guard let organizedPath, !organizedPath.isEmpty else { return .none }
        guard (organizedPath as NSString).isAbsolutePath else { return .libraryFolder }
        return .absolute(volumePath: MountObserver.extractVolumePath(from: organizedPath))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    /// `yyyy-MM-dd…` → the user's abbreviated date (`4 Oct 2026`, UC-COPY-10); formatted once
    /// per distinct day.
    static func dayText(_ stamp: String, cache: inout [Substring: String]) -> String? {
        let day = stamp.prefix(10)
        if let cached = cache[day] { return cached }
        let parts = day.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]),
              let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: dayOfMonth))
        else { return nil }
        let text = date.formatted(date: .abbreviated, time: .omitted)
        cache[day] = text
        return text
    }
}

// MARK: - Sorting (UC-TABLE-04)

/// Sorts rows for a `TrackSortOrder`: absent values last in both directions, ties in the
/// container's order, text compared case- and diacritic-insensitively. Keys are folded once
/// per sort, so 15,000 rows sort in a few milliseconds.
enum TrackRowSorter {
    static func sorted(_ rows: [TrackRow], by order: TrackSortOrder?) -> [TrackRow] {
        guard let order, !order.isContainerOrder else {
            return isInPositionOrder(rows) ? rows : rows.sorted { $0.position < $1.position }
        }
        if order.column == .number {
            return rows.sorted { $0.position > $1.position }
        }
        var indices = Array(rows.indices)
        let ascending = order.ascending
        if let textKey = textKey(order.column) {
            let keys: [String?] = rows.map { row in textKey(row).map(fold) }
            indices.sort { a, b in
                switch compare(keys[a], keys[b], ascending: ascending) {
                case .some(let result): return result
                case .none: return rows[a].position < rows[b].position
                }
            }
        } else {
            let numberKey = numberKey(order.column)
            let keys: [Double?] = rows.map(numberKey)
            indices.sort { a, b in
                switch compare(keys[a], keys[b], ascending: ascending) {
                case .some(let result): return result
                case .none: return rows[a].position < rows[b].position
                }
            }
        }
        return indices.map { rows[$0] }
    }

    /// `true`/`false` = ordered; `nil` = tie. `nil` values always go last.
    private static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?, ascending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        case let (l?, r?):
            if l == r { return nil }
            return ascending ? l < r : l > r
        }
    }

    private static func textKey(_ column: TrackColumnID) -> ((TrackRow) -> String?)? {
        switch column {
        case .title: { $0.title }
        case .artist: { $0.artistText }
        case .album: { $0.albumText }
        case .genre: { $0.genreText }
        case .format: { $0.formatText }
        case .added: { $0.addedSortValue.isEmpty ? nil : $0.addedSortValue }
        default: nil
        }
    }

    private static func numberKey(_ column: TrackColumnID) -> (TrackRow) -> Double? {
        switch column {
        case .time: { $0.track.duration.flatMap { $0 > 0 ? Double($0) : nil } }
        case .bpm: { $0.track.bpm.flatMap { $0 > 0 ? Double($0) : nil } }
        case .energy: { $0.energyLevel.map(Double.init) }
        case .dance: { $0.track.danceability }
        case .year: { $0.track.year.flatMap { $0 > 0 ? Double($0) : nil } }
        case .kbps: { $0.track.bitrate.flatMap { $0 > 0 ? Double($0) : nil } }
        case .status: { Double($0.availability.statusSortRank) }
        case .match, .suggestion: { $0.matchPercent.map(Double.init) }
        default: { Double($0.position) }
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func isInPositionOrder(_ rows: [TrackRow]) -> Bool {
        zip(rows, rows.dropFirst()).allSatisfy { $0.position < $1.position }
    }
}

// MARK: - Durations (UC-COPY-10)

enum TrackDurationText {
    /// `3:24`, `1:02:05`; `nil` when unknown.
    static func trackTime(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        if hours > 0 {
            return "\(hours):" + twoDigits(minutes) + ":" + twoDigits(rest)
        }
        return "\(minutes):" + twoDigits(rest)
    }

    /// Totals: `< 90 min` → `52 min`; `< 24 h` → `2 h 51 min`; else `38 days`.
    static func total(_ seconds: Int) -> String {
        let minutes = Int((Double(max(seconds, 0)) / 60).rounded())
        if minutes < 90 { return "\(minutes) min" }
        if minutes < 24 * 60 { return "\(minutes / 60) h \(minutes % 60) min" }
        let days = Int((Double(minutes) / (24 * 60)).rounded())
        return days == 1 ? "1 day" : "\(days.formatted(.number)) days"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
