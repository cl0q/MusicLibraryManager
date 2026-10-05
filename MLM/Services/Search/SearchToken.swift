import Foundation

// MARK: - Search tokens (UC-SEARCH-04, V-SEARCH.N01/N16, DEC-017)

/// The filter words of the search field. Typing `artist:`, `album:`, `genre:`, `year:`, `bpm:`
/// or `is:` offers values; a chosen value becomes a token inside the field. Kinds combine with
/// AND, values of one kind with OR (`SearchFilter`).
enum SearchTokenKind: String, CaseIterable, Codable, Sendable {
    case artist, album, genre, year, bpm
    /// `is:` — availability words and facts.
    case availability = "is"

    /// What the user types: `artist`, `bpm`, `is` (followed by `:`).
    var keyword: String { rawValue }

    /// `artist:` — the filter word as shown in suggestions.
    var prefix: String { "\(keyword):" }

    /// The hint after the filter word in the suggestions (`search.html` V-SEARCH.E06).
    var hint: String {
        switch self {
        case .artist: "an artist"
        case .album: "an album"
        case .genre: "a genre"
        case .year: "2019 or 2015–2019"
        case .bpm: "a tempo or range"
        case .availability: "not downloaded, download failed, file missing, no album …"
        }
    }

    /// Kinds whose value is free text from the library (the others are numbers or words).
    var takesText: Bool {
        switch self {
        case .artist, .album, .genre: true
        case .year, .bpm, .availability: false
        }
    }
}

/// The words `is:` understands (`search.html` V-SEARCH.N16), in suggestion order: the
/// availability words of §15.4 first, then the facts.
enum SearchAvailabilityWord: String, CaseIterable, Codable, Sendable {
    case notDownloaded = "not downloaded"
    case downloadFailed = "download failed"
    case fileMissing = "file missing"
    case local = "local"
    case noAlbum = "no album"
    case notAnalysed = "not analysed"
    case inNoPlaylist = "in no playlist"
    case linkedToSoundCloud = "linked to SoundCloud"
    case linkedToSpotify = "linked to Spotify"
    case linkedToYouTube = "linked to YouTube"

    /// The phrase as typed and shown (`not downloaded`, `linked to SoundCloud`).
    var phrase: String { rawValue }

    /// Extra spellings that resolve to the same word.
    var alternatePhrases: [String] {
        switch self {
        case .notAnalysed: ["not analyzed"]
        default: []
        }
    }

    /// The words after the availability group (separated in the suggestions).
    var isFact: Bool {
        switch self {
        case .notDownloaded, .downloadFailed, .fileMissing, .local: false
        default: true
        }
    }

    /// The word whose phrase (or an alternate) equals `text`, ignoring case.
    static func exact(_ text: String) -> SearchAvailabilityWord? {
        let folded = text.trimmingCharacters(in: .whitespaces).lowercased()
        return allCases.first { word in
            word.phrase.lowercased() == folded || word.alternatePhrases.contains(folded)
        }
    }
}

/// An inclusive number range: `bpm: 120–128` → 120…128, `year: 2019` → 2019…2019.
struct SearchNumberRange: Hashable, Codable, Sendable {
    let lower: Int
    let upper: Int

    init(_ lower: Int, _ upper: Int) {
        self.lower = min(lower, upper)
        self.upper = max(lower, upper)
    }

    func contains(_ value: Int) -> Bool { value >= lower && value <= upper }

    /// `120–128` (U+2013, UC-COPY-08) or `2019` for a single value.
    var text: String { lower == upper ? "\(lower)" : "\(lower)–\(upper)" }

    /// `128`, `120–128`, `120-128`, `120—128`, `120..128`; `nil` for anything else.
    static func parse(_ raw: String) -> SearchNumberRange? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let single = Int(trimmed), single >= 0 { return SearchNumberRange(single, single) }
        for separator in ["–", "—", "..", "-"] {
            let parts = trimmed.components(separatedBy: separator)
            guard parts.count == 2 else { continue }
            let lhs = parts[0].trimmingCharacters(in: .whitespaces)
            let rhs = parts[1].trimmingCharacters(in: .whitespaces)
            if let lower = Int(lhs), let upper = Int(rhs), lower >= 0, upper >= 0 {
                return SearchNumberRange(lower, upper)
            }
        }
        return nil
    }
}

/// What a token matches.
enum SearchTokenValue: Hashable, Codable, Sendable {
    /// Artist, album or genre text. `exact` = chosen from the library's values (equality,
    /// ignoring case); typed values match where the field *contains* them.
    case text(String, exact: Bool)
    /// Year or BPM, inclusive.
    case range(SearchNumberRange)
    /// An `is:` word.
    case word(SearchAvailabilityWord)
}

/// One token of the search field (`genre: Techno`, `is: not downloaded`, `bpm: 120–128`).
struct SearchToken: Identifiable, Hashable, Codable, Sendable {
    let kind: SearchTokenKind
    let value: SearchTokenValue

    init(kind: SearchTokenKind, value: SearchTokenValue) {
        self.kind = kind
        self.value = value
    }

    static func artist(_ name: String, exact: Bool = true) -> SearchToken {
        SearchToken(kind: .artist, value: .text(name, exact: exact))
    }

    static func album(_ name: String, exact: Bool = true) -> SearchToken {
        SearchToken(kind: .album, value: .text(name, exact: exact))
    }

    static func genre(_ name: String, exact: Bool = true) -> SearchToken {
        SearchToken(kind: .genre, value: .text(name, exact: exact))
    }

    static func year(_ range: SearchNumberRange) -> SearchToken {
        SearchToken(kind: .year, value: .range(range))
    }

    static func bpm(_ range: SearchNumberRange) -> SearchToken {
        SearchToken(kind: .bpm, value: .range(range))
    }

    static func availability(_ word: SearchAvailabilityWord) -> SearchToken {
        SearchToken(kind: .availability, value: .word(word))
    }

    /// The value as shown after `kind:` (`Techno`, `120–128`, `not downloaded`).
    var valueText: String {
        switch value {
        case .text(let text, _): text
        case .range(let range): range.text
        case .word(let word): word.phrase
        }
    }

    /// `genre: Techno` — the token's label in the field, recent searches and help.
    var displayText: String { "\(kind.keyword): \(valueText)" }

    /// Stable identity: kind, match mode and the value, case-folded for text.
    var id: String {
        switch value {
        case .text(let text, let exact):
            "\(kind.keyword):\(exact ? "=" : "~")\(text.lowercased())"
        case .range(let range):
            "\(kind.keyword):\(range.lower)-\(range.upper)"
        case .word(let word):
            "\(kind.keyword):\(word.rawValue)"
        }
    }
}
