import Foundation

// MARK: - What a genre is (V-GENRES, DEC-025)

/// Genre identity and display, one rule for the whole Genres place.
///
/// **Identity:** a genre is `tracks.genre` trimmed and lower-cased (`key(_:)`). Imported files
/// store their genre lower-cased (`MetadataExtractor`), typed genres keep the user's casing, so
/// `house` (imported) and `House` (typed) are one genre — the old Workshop showed them as two
/// because its grouping was case-sensitive. Spelling variants that differ in more than case
/// (`Hip Hop` / `Hip-Hop` / `HipHop`) stay separate genres; Merge Genres… joins them.
///
/// **Display rule:** among the stored spellings of a genre, the most frequent one that has an
/// upper-case letter — the casing a person wrote (ties: the alphabetically first); when every
/// spelling is lower-case (only imported tags), the key with the first letter of each word
/// capitalised (`drum & bass` → `Drum & Bass`, `uk garage` → `Uk Garage`).
enum GenreName {
    /// The identity of a stored or typed genre; nil for no genre (nil, empty or blank).
    static func key(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    /// A typed genre name as it is stored: trimmed, inner runs of whitespace collapsed; nil when
    /// nothing is left.
    static func cleaned(_ typed: String) -> String? {
        let words = typed.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }

    /// The display name of a genre from its stored spellings and their track counts.
    static func display(spellings: [(spelling: String, count: Int)]) -> String {
        let cleaned = spellings.compactMap { item -> (String, Int)? in
            let trimmed = item.spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (trimmed, item.count)
        }
        // Several stored spellings can trim to the same text: count them together.
        var counts: [String: Int] = [:]
        for (spelling, count) in cleaned { counts[spelling, default: 0] += count }
        let written = counts.filter { $0.key != $0.key.lowercased() }
        if let best = written.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first {
            return best.key
        }
        guard let any = counts.keys.sorted().first else { return "" }
        return capitalized(any)
    }

    /// `drum & bass` → `Drum & Bass`, `hip-hop` → `Hip-Hop`, `r&b` → `R&B`: the first letter of
    /// every word (after a space, `-`, `/`, `&`, `(` or `+`) upper-cased, the rest unchanged.
    static func capitalized(_ text: String) -> String {
        var result = ""
        var atWordStart = true
        for character in text {
            if atWordStart, character.isLetter {
                result += character.uppercased()
                atWordStart = false
            } else {
                result.append(character)
                atWordStart = character.isWhitespace || "-/&(+".contains(character)
            }
        }
        return result
    }
}

// MARK: - One genre of the list

/// One row of V-GENRES: the genre's display name, how many tracks carry it and their total
/// time, plus the exact stored spellings (what its tracks are found by).
struct GenreSummary: Identifiable, Hashable, Sendable {
    /// `GenreName.key` — the identity.
    let key: String
    let name: String
    let trackCount: Int
    /// Total duration in seconds.
    let duration: Int
    /// The exact `tracks.genre` values of this genre.
    let spellings: [String]

    var id: String { key }
}

/// Everything the Genres list shows (status bar, footer line).
struct GenreOverview: Equatable, Sendable {
    var genres: [GenreSummary]
    /// Tracks with no genre (nil, empty or blank).
    var tracksWithoutGenre: Int

    var tracksWithGenre: Int { genres.reduce(0) { $0 + $1.trackCount } }

    static let empty = GenreOverview(genres: [], tracksWithoutGenre: 0)

    /// Folds `GROUP BY genre` rows (exact spellings) into genres by key.
    static func fold(rows: [(genre: String, count: Int, duration: Int)], totalTracks: Int) -> GenreOverview {
        var byKey: [String: [(genre: String, count: Int, duration: Int)]] = [:]
        for row in rows {
            guard let key = GenreName.key(row.genre) else { continue }
            byKey[key, default: []].append(row)
        }
        let genres = byKey.map { key, rows in
            GenreSummary(
                key: key,
                name: GenreName.display(spellings: rows.map { ($0.genre, $0.count) }),
                trackCount: rows.reduce(0) { $0 + $1.count },
                duration: rows.reduce(0) { $0 + $1.duration },
                spellings: rows.map(\.genre).sorted()
            )
        }
        .sorted { $0.trackCount != $1.trackCount ? $0.trackCount > $1.trackCount : $0.name < $1.name }
        let withGenre = genres.reduce(0) { $0 + $1.trackCount }
        return GenreOverview(genres: genres, tracksWithoutGenre: max(totalTracks - withGenre, 0))
    }
}

// MARK: - Spelling variants (V-GENRES.N03 “Looks like …”)

/// Points out genres that are probably spellings of another (`Hip Hop` / `HipHop` / `Hip-Hop`,
/// `Drum and Bass` / `Drum & Bass`, `tech-house` / `Tech House`): same letters and digits once
/// spaces, hyphens, `&` and the word `and` are ignored. A hint, never an automatic change —
/// `Merge…` opens the merge sheet with the variants selected.
enum GenreLookalikes {
    /// The comparison form: `drum & bass` and `Drum and Bass` → `drumbass`.
    static func signature(_ name: String) -> String {
        let words = name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0 != "and" && $0 != "n" }
        return words.joined()
    }

    /// For each genre that looks like a larger one: its key → the larger genre (the largest of
    /// its group). The largest of each group gets no hint.
    static func hints(_ genres: [GenreSummary]) -> [String: GenreSummary] {
        var groups: [String: [GenreSummary]] = [:]
        for genre in genres {
            let signature = signature(genre.name)
            guard !signature.isEmpty else { continue }
            groups[signature, default: []].append(genre)
        }
        var result: [String: GenreSummary] = [:]
        for members in groups.values where members.count > 1 {
            let ordered = members.sorted { $0.trackCount != $1.trackCount ? $0.trackCount > $1.trackCount : $0.name < $1.name }
            for genre in ordered.dropFirst() { result[genre.key] = ordered[0] }
        }
        return result
    }

    /// The genres that look like `genre` (itself included), largest first.
    static func group(of genre: GenreSummary, in genres: [GenreSummary]) -> [GenreSummary] {
        let signature = signature(genre.name)
        return genres.filter { $0.key == genre.key || (!signature.isEmpty && Self.signature($0.name) == signature) }
            .sorted { $0.trackCount != $1.trackCount ? $0.trackCount > $1.trackCount : $0.name < $1.name }
    }
}

// MARK: - Words

enum GenreText {
    /// `48 genres`.
    static func genres(_ n: Int) -> String { StatusBarText.count(n, "genre", "genres") }

    /// `412 tracks · 1 day · 118–134 BPM` (the detail header's facts, V-GENRED).
    static func facts(trackCount: Int, duration: Int, bpms: [Int]) -> String {
        var parts = [StatusBarText.tracks(trackCount), TrackDurationText.total(duration)]
        let valid = bpms.filter { $0 > 0 }
        if let low = valid.min(), let high = valid.max() {
            parts.append(low == high ? "\(low) BPM" : "\(low)–\(high) BPM")
        }
        return parts.joined(separator: " · ")
    }

    /// `“Techno”` · `3 genres` — a genre subject in a sentence.
    static func subject(_ names: [String]) -> String {
        names.count == 1 ? "“\(names[0])”" : genres(names.count)
    }
}
