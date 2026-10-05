import Foundation
import GRDB

// MARK: - Fields

/// The tags Info ▸ Details edits and MLM writes into audio files (DEC-007, THOUGHTS §10 Q7).
///
/// Only fields the `tracks` table has today. Track/Disc number and Comment have no column yet
/// (album order arrives with W4's `album_tracks`), so they are not offered. Provenance (the
/// source) is never a field and never goes into a file (L10).
enum TrackTagField: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case title
    case artist
    case album
    case albumArtist = "album_artist"
    case genre
    case year
    case bpm

    var id: String { rawValue }

    /// The `tracks` column.
    var column: String { rawValue }

    /// Form label, sentence case (UC-COPY-03).
    var label: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .albumArtist: "Album artist"
        case .genre: "Genre"
        case .year: "Year"
        case .bpm: "BPM"
        }
    }

    /// Title Case name for undo action names (UC-COPY-02, UC-UNDO-07).
    var titleCaseName: String {
        switch self {
        case .albumArtist: "Album Artist"
        default: label
        }
    }

    /// The field inside a status-bar sentence: `Changed genre of 14 tracks`.
    var sentenceName: String {
        switch self {
        case .bpm: "BPM"
        default: label.lowercased()
        }
    }

    /// Edit ▸ Undo ‹action› (UC-UNDO-07): `Edit Genre`.
    var actionName: String { "Edit \(titleCaseName)" }

    /// Numeric fields (`year`, `bpm`): monospaced digits, number validation.
    var isNumeric: Bool { self == .year || self == .bpm }

    /// The column may hold `NULL` (`genre`, `year`, `bpm`); the others are `NOT NULL` text.
    fileprivate var isNullable: Bool {
        switch self {
        case .genre, .year, .bpm: true
        case .title, .artist, .album, .albumArtist: false
        }
    }

    /// Stable order for storage (`pending_tag_writes.fields`).
    static func encode(_ fields: Set<TrackTagField>) -> String {
        allCases.filter(fields.contains).map(\.rawValue).joined(separator: ",")
    }

    static func decode(_ text: String) -> Set<TrackTagField> {
        Set(text.split(separator: ",").compactMap { TrackTagField(rawValue: String($0)) })
    }
}

// MARK: - Values

/// A field's stored value: text for the text columns (`nil` only where the column allows it),
/// a number or nothing for `year` / `bpm`.
enum TrackTagValue: Sendable, Hashable, Codable {
    case text(String?)
    case number(Int?)

    /// The value of `field` on `track`, exactly as stored.
    static func stored(_ field: TrackTagField, of track: Track) -> TrackTagValue {
        switch field {
        case .title: .text(track.title)
        case .artist: .text(track.artist)
        case .album: .text(track.album)
        case .albumArtist: .text(track.albumArtist)
        case .genre: .text(track.genre)
        case .year: .number(track.year)
        case .bpm: .number(track.bpm)
        }
    }

    /// The value as SQLite stores it in `field`'s column (`NOT NULL` text columns get `""`
    /// for nothing).
    func databaseValue(for field: TrackTagField) -> DatabaseValue {
        switch self {
        case .text(let text):
            if let text { return text.databaseValue }
            return field.isNullable ? .null : "".databaseValue
        case .number(let number):
            return number?.databaseValue ?? .null
        }
    }

    /// Apply to an in-memory track (for `search_text` and tests).
    func apply(_ field: TrackTagField, to track: inout Track) {
        switch (field, self) {
        case (.title, .text(let text)): track.title = text ?? ""
        case (.artist, .text(let text)): track.artist = text ?? ""
        case (.album, .text(let text)): track.album = text ?? ""
        case (.albumArtist, .text(let text)): track.albumArtist = text ?? ""
        case (.genre, .text(let text)): track.genre = text
        case (.year, .number(let number)): track.year = number
        case (.bpm, .number(let number)): track.bpm = number
        default: break
        }
    }
}

// MARK: - Form text and validation (UC-TRAIL-04, P-INSPECTOR.N08)

/// Why a typed value isn't saved: said under the field, which stays open with the text.
struct TrackTagValidationError: Error, Equatable, Sendable {
    let message: String
    /// For `‹Field› wasn’t changed — ‹reason›` when the field is no longer on screen.
    var shortReason: String {
        if message.hasPrefix("A track needs") { return message.components(separatedBy: ".").first?.lowercased() ?? message }
        return message.hasSuffix(".") ? String(message.dropLast()).lowercased() : message.lowercased()
    }
}

extension TrackTagField {
    /// What the field shows for `track`. Placeholders (`unknown album`, a source name as album,
    /// `unknown artist`) show as an empty field, never as the literal (DEC-013, UC-TABLE-11).
    func text(of track: Track) -> String {
        switch self {
        case .title: track.title
        case .artist: TrackMetadataPresentation.artistDisplay(track.artist) ?? ""
        case .album: TrackMetadataPresentation.albumDisplay(track.album) ?? ""
        case .albumArtist: track.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        case .genre: track.genre?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .year: track.year.flatMap { $0 > 0 ? String($0) : nil } ?? ""
        case .bpm: track.bpm.flatMap { $0 > 0 ? String($0) : nil } ?? ""
        }
    }

    /// The value a typed text stands for, or why it can't be saved.
    func parse(_ text: String) -> Result<TrackTagValue, TrackTagValidationError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .title:
            guard !trimmed.isEmpty else {
                return .failure(.init(message: "A track needs a title. Press Esc to restore the old one."))
            }
            return .success(.text(trimmed))
        case .artist:
            guard !trimmed.isEmpty else {
                return .failure(.init(message: "A track needs an artist. Press Esc to restore the old one."))
            }
            return .success(.text(trimmed))
        case .album, .albumArtist:
            return .success(.text(trimmed))
        case .genre:
            return .success(.text(trimmed.isEmpty ? nil : trimmed))
        case .year:
            guard !trimmed.isEmpty else { return .success(.number(nil)) }
            guard trimmed.count <= 4, trimmed.allSatisfy(\.isASCIIDigit), let year = Int(trimmed), year > 0 else {
                return .failure(.init(message: "Year is a number, like 2019."))
            }
            return .success(.number(year))
        case .bpm:
            guard !trimmed.isEmpty else { return .success(.number(nil)) }
            guard trimmed.count <= 3, trimmed.allSatisfy(\.isASCIIDigit), let bpm = Int(trimmed), bpm > 0 else {
                return .failure(.init(message: "BPM is a number, like 128."))
            }
            return .success(.number(bpm))
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
