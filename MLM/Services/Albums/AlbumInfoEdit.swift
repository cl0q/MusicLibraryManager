import Foundation
import GRDB

// Edit Album Info (S-ALB-EDIT, IMP-093): the sheet's form rules and the one undo step it saves.
// The album row and the album fields of its listed tracks change together; the tracks go through
// `TrackTagEdit`, so `Write tags to files` and the drive wait (IMP-030) are honoured, and nothing
// else touches a file (the cover is `AlbumCoverFiles`).

// MARK: - Values and the form

/// What the sheet shows and saves.
struct AlbumInfoValues: Equatable, Sendable {
    var title: String
    var albumArtist: String
    var year: Int?
    /// nil = no genre.
    var genre: String?
}

enum AlbumInfoRules {
    static let variousArtists = "Various Artists"

    static func isVariousArtists(_ artist: String) -> Bool {
        artist.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(variousArtists) == .orderedSame
    }

    /// The most common track artist (ties: the alphabetically first), for the Compilation toggle
    /// going off.
    static func majorityArtist(of tracks: [Track]) -> String? {
        var counts: [String: Int] = [:]
        for track in tracks {
            let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !artist.isEmpty { counts[artist, default: 0] += 1 }
        }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }

    /// The tag fields whose value differs, in the order they are written.
    static func changedFields(from original: AlbumInfoValues, to new: AlbumInfoValues) -> [TrackTagField] {
        var fields: [TrackTagField] = []
        if new.title != original.title { fields.append(.album) }
        if new.albumArtist != original.albumArtist { fields.append(.albumArtist) }
        if new.year != original.year { fields.append(.year) }
        if new.genre != original.genre { fields.append(.genre) }
        return fields
    }

    /// Whether the `albums` row itself changes (title, album artist or year).
    static func rowChanges(from original: AlbumInfoValues, to new: AlbumInfoValues) -> Bool {
        new.title != original.title || new.albumArtist != original.albumArtist || new.year != original.year
    }

    /// Existing genres that complete what is typed: the names that start with it (folded), not
    /// the exact name already typed, at most `limit`.
    static func genreSuggestions(typed: String, existing: [String], limit: Int = 5) -> [String] {
        guard let cleaned = GenreName.cleaned(typed) else { return [] }
        let wanted = SearchFilter.fold(cleaned)
        return Array(existing.filter { name in
            let folded = SearchFilter.fold(name)
            return folded.hasPrefix(wanted) && folded != wanted
        }.prefix(limit))
    }
}

/// The Edit Album Info form: the fields as typed, the Compilation toggle and what is wrong.
struct AlbumInfoForm: Equatable, Sendable {
    enum Problem: Equatable, Sendable {
        case emptyTitle
        case emptyAlbumArtist
        case badYear
    }

    let original: AlbumInfoValues
    /// The most common track artist; the album artist field's value when Compilation goes off.
    let majorityArtist: String?
    var title: String
    var albumArtist: String
    var yearText: String
    var genre: String
    private(set) var isCompilation: Bool

    /// - Parameters:
    ///   - album: the album row.
    ///   - tracks: its listed tracks (the genre and, without a year on the album, the year).
    init(album: Album, tracks: [Track]) {
        let genres = tracks.compactMap { track -> String? in
            let genre = track.genre?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return genre.isEmpty ? nil : genre
        }
        let years = tracks.compactMap(\.year).filter { $0 > 0 }
        original = AlbumInfoValues(
            title: album.title, albumArtist: album.albumArtist,
            year: album.year ?? AlbumRepository.majority(years), genre: AlbumRepository.majority(genres))
        majorityArtist = AlbumInfoRules.majorityArtist(of: tracks)
        title = album.title
        albumArtist = album.albumArtist
        yearText = original.year.map(String.init) ?? ""
        genre = original.genre ?? ""
        isCompilation = AlbumInfoRules.isVariousArtists(album.albumArtist)
    }

    /// Compilation on: the album artist becomes `Various Artists` (and the field is disabled);
    /// off: it is editable again and prefilled with the majority track artist.
    mutating func setCompilation(_ on: Bool) {
        guard on != isCompilation else { return }
        isCompilation = on
        if on {
            albumArtist = AlbumInfoRules.variousArtists
        } else {
            let fallback = AlbumInfoRules.isVariousArtists(original.albumArtist) ? "" : original.albumArtist
            albumArtist = majorityArtist ?? fallback
        }
    }

    /// The first thing that stops Save, if anything.
    var problem: Problem? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyTitle }
        if albumArtistValue.isEmpty { return .emptyAlbumArtist }
        if year == .invalid { return .badYear }
        return nil
    }

    private enum Year: Equatable { case none, valid(Int), invalid }

    private var year: Year {
        let trimmed = yearText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .none }
        guard let value = Int(trimmed), (1000...9999).contains(value) else { return .invalid }
        return .valid(value)
    }

    private var albumArtistValue: String {
        isCompilation ? AlbumInfoRules.variousArtists : albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The values to save; nil while something is wrong.
    var values: AlbumInfoValues? {
        guard problem == nil else { return nil }
        let yearValue: Int?
        if case .valid(let value) = year { yearValue = value } else { yearValue = nil }
        return AlbumInfoValues(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), albumArtist: albumArtistValue,
            year: yearValue, genre: GenreName.cleaned(genre))
    }

    /// Valid and different from what the album has.
    var hasChanges: Bool { values.map { $0 != original } ?? false }

    /// The sentence under the field that is wrong.
    static func sentence(for problem: Problem) -> String {
        switch problem {
        case .emptyTitle: "Enter a title."
        case .emptyAlbumArtist: "Enter an album artist."
        case .badYear: "Enter a four-digit year, or leave it empty."
        }
    }

    /// The key collision sentence (IMP-093): shown above the buttons, Save disabled.
    static let keyTaken = "A base album with this title already exists. Use Merge with Another Album…"
}

// MARK: - Words

@MainActor
enum AlbumInfoText {
    /// `Applies to the album and its 10 tracks in the library.`
    static func subtitle(trackCount: Int) -> String {
        "Applies to the album and its \(StatusBarText.tracks(trackCount)) in the library."
    }

    /// The footnote under the form: nothing while `Write tags to files` is off; the file sentence
    /// while it is on; the waiting sentence as well while the drive is away.
    static func footnote(writesTags: Bool, offlineVolume: String?) -> String? {
        guard writesTags else { return nil }
        var text = "Saved to the library and, because “Write tags to files” is on in Settings ▸ Library, to the tags of the files."
        if let offlineVolume {
            text += " While “\(offlineVolume)” is not connected the tag changes wait in Activity."
        }
        return text
    }

    static let undoNote = "One undo step (⌘Z)"

    static func saved(_ title: String, waiting: Int?, volume: String?) -> String {
        var text = "Edited “\(title)”"
        if let waiting, waiting > 0 { text += " · " + TrackTagEdit.waitingText(waiting, volume: volume) }
        return text
    }
}

// MARK: - Reads

extension AlbumRepository {
    /// Another album with this (album artist, title) key and edition kind — the key the unique
    /// index guards. Compared by the Swift key (`AlbumKey.rowKey`), never the stored
    /// `title_normalized`, which an older app wrote in another form.
    func albumWithKey(albumArtist: String, title: String, variantKind: String?, excluding albumID: Int64) async throws -> Album? {
        let wanted = AlbumKey.key(artist: albumArtist, title: title)
        return try await database.read { db in
            try Album.fetchAll(db, sql: """
                SELECT * FROM albums WHERE id <> ? AND IFNULL(variant_kind, '') = IFNULL(?, '') ORDER BY id
                """, arguments: [albumID, variantKind]).first {
                AlbumKey.rowKey(albumArtist: $0.albumArtist, artist: $0.artist, title: $0.title) == wanted
            }
        }
    }
}

// MARK: - The edit

enum AlbumInfoError: Error, Equatable {
    /// Another album already has the new title and album artist.
    case keyTaken
}

struct AlbumInfoOutcome: Sendable, Equatable {
    let title: String
    let trackCount: Int
    /// Tag changes waiting for the drive after the step.
    let waiting: Int?
}

extension ShellEdits {
    /// Save in Edit Album Info: **one** undo step, `Edit Album Info` — the `albums` row (title,
    /// album artist, year, `title_normalized` through `AlbumKey.normalize`), the cover when one was
    /// chosen, and the changed album fields of `trackIDs` through `tagEdit`. Nil when nothing
    /// changed. Throws `AlbumInfoError.keyTaken` (nothing was written) when another album already
    /// has the new key, `AlbumCoverFiles.Failure` when the image can't be used (nothing stays
    /// written), or the database error.
    @discardableResult
    func editAlbumInfo(
        albumID: Int64, original: AlbumInfoValues, new: AlbumInfoValues, trackIDs: [Int64],
        cover: CoverSource? = nil, coversDirectory: URL? = nil, tagEdit: TrackTagEdit, volumeName: String? = nil
    ) async throws -> AlbumInfoOutcome? {
        guard let albums = dependencies.albums() else { throw UndoTargetMissing(quotedName: "The album") }
        guard let album = try await albums.fetch(id: albumID) else { throw UndoTargetMissing(quotedName: "“\(original.title)”") }
        let fields = AlbumInfoRules.changedFields(from: original, to: new)
        let rowChanges = AlbumInfoRules.rowChanges(from: original, to: new)
        guard !fields.isEmpty || rowChanges || cover != nil else { return nil }
        if new.title != original.title || new.albumArtist != original.albumArtist {
            let holder = try await albums.albumWithKey(albumArtist: new.albumArtist, title: new.title,
                                                       variantKind: album.variantKind, excluding: albumID)
            if holder != nil { throw AlbumInfoError.keyTaken }
        }
        let reference = try cover.map { try AlbumCoverFiles.store($0, albumID: albumID, in: coversDirectory) }
        let database = albums.database
        let sentTracks = trackIDs.count
        return try await undo.performGroup(
            "Edit Album Info", failure: nil,
            { group in
                if rowChanges {
                    try await group.perform(
                        do: { () async throws -> AlbumRowChange in
                            let change = try await database.write { db in
                                try AlbumRowChange.apply(db, albumID: albumID, original: original, new: new)
                            }
                            NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
                            return change
                        },
                        undo: { (change: AlbumRowChange) async throws -> AlbumRowChange in
                            try await database.write { db in try change.write(db, change.before) }
                            NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
                            return change
                        },
                        redo: { (change: AlbumRowChange) async throws -> AlbumRowChange in
                            try await database.write { db in try change.write(db, change.after) }
                            NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
                            return change
                        })
                }
                if let reference {
                    try await group.perform(
                        do: { () async throws -> String? in
                            let before = try await albums.setCoverPath(albumID: albumID, to: reference)
                            Self.coverDidChange(albumID)
                            return before
                        },
                        undo: { (before: String?) async throws -> String? in
                            let current = try await albums.setCoverPath(albumID: albumID, to: before)
                            Self.coverDidChange(albumID)
                            return current
                        },
                        redo: { (_: String?) async throws -> String? in
                            let before = try await albums.setCoverPath(albumID: albumID, to: reference)
                            Self.coverDidChange(albumID)
                            return before
                        })
                }
                var waiting: Int?
                for field in fields {
                    let value: TrackTagValue
                    switch field {
                    case .album: value = .text(new.title)
                    case .albumArtist: value = .text(new.albumArtist)
                    case .year: value = .number(new.year)
                    default: value = .text(new.genre)
                    }
                    if let step = try await tagEdit.perform(value, field: field, trackIDs: trackIDs, in: group), let wait = step.waiting {
                        waiting = max(waiting ?? 0, wait)
                    }
                }
                return AlbumInfoOutcome(title: new.title, trackCount: sentTracks, waiting: waiting)
            },
            message: { AlbumInfoText.saved($0.title, waiting: $0.waiting, volume: volumeName) })
    }
}

/// The `albums` row's title, album artist and year before and after an edit (undo and redo).
struct AlbumRowChange: Sendable, Equatable {
    struct Fields: Sendable, Equatable {
        var title: String
        var albumArtist: String
        var year: Int?
    }

    let albumID: Int64
    let before: Fields
    let after: Fields

    /// Writes the new values over the row as it is now (only what changed); returns both sides.
    static func apply(_ db: Database, albumID: Int64, original: AlbumInfoValues, new: AlbumInfoValues) throws -> AlbumRowChange {
        guard let row = try Album.fetchOne(db, key: albumID) else { throw UndoTargetMissing(quotedName: "“\(original.title)”") }
        let before = Fields(title: row.title, albumArtist: row.albumArtist, year: row.year)
        var after = before
        if new.title != original.title { after.title = new.title }
        if new.albumArtist != original.albumArtist { after.albumArtist = new.albumArtist }
        if new.year != original.year { after.year = new.year }
        let change = AlbumRowChange(albumID: albumID, before: before, after: after)
        try change.write(db, after)
        return change
    }

    func write(_ db: Database, _ fields: Fields) throws {
        try db.execute(sql: "UPDATE albums SET title = ?, album_artist = ?, year = ?, title_normalized = ? WHERE id = ?",
                       arguments: [fields.title, fields.albumArtist, fields.year, AlbumKey.normalize(fields.title), albumID])
    }
}
