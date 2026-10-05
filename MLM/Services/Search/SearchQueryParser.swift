import Foundation

// MARK: - Typed text → free text + tokens (UC-SEARCH-04)

/// The clause the caret is in at the end of the text — what the value suggestions are for
/// (`genre: te` → genres starting with or containing “te”).
struct SearchTrailingClause: Equatable, Sendable {
    let kind: SearchTokenKind
    /// What has been typed after `kind:` so far, trimmed (may be empty).
    let partialValue: String
    /// The text before the clause (`remix ` for `remix genre: te`), trailing spaces trimmed —
    /// what stays in the field when the clause becomes a token.
    let textBefore: String
}

/// The search text, parsed. Pure and unit-tested (`SearchQueryParserTests`).
struct ParsedSearchText: Equatable, Sendable {
    /// Words that aren't part of a clause, joined by single spaces.
    var freeText = ""
    /// Clauses whose value is understood (applied as filters).
    var tokens: [SearchToken] = []
    /// The last clause when the text ends inside it (drives the value suggestions).
    var trailing: SearchTrailingClause?
    /// Clauses typed with a value MLM doesn't understand (`bpm: fast`, `is: shiny`). They are
    /// not applied — the suggestions show the valid forms.
    var unresolved: [String] = []

    var freeTerms: [String] {
        freeText.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// The token grammar of the search field:
///
/// | Typed | Means |
/// |---|---|
/// | `artist: Skee Mask` | artist or album artist contains “Skee Mask” (typed text matches where it is contained) |
/// | `artist:"Skee Mask"` | artist or album artist is exactly “Skee Mask” (ignoring case) — like a chosen suggestion |
/// | `album:` / `genre:` | the same for album / genre |
/// | `year: 2019`, `year: 2015–2019` | year in the inclusive range (`-`, `–`, `—`, `..` all work) |
/// | `bpm: 128`, `bpm: 120–128` | BPM in the inclusive range |
/// | `is: not downloaded` … | one of `SearchAvailabilityWord` (longest phrase wins; the rest is free text) |
///
/// - An unquoted artist / album / genre value runs to the next filter word or the end of the
///   text, so free words go *before* the filters (`remix genre: techno`) or the value is quoted
///   (`genre:"Techno" remix`).
/// - `year:` / `bpm:` take one number or range; words after it are free text.
/// - Filter words are recognised only at the start of a word and only for the six kinds;
///   anything else with a colon (`Re:Edit`, a URL) is free text.
/// - A value that can't be understood is listed in `unresolved` and not applied.
enum SearchQueryParser {
    static func parse(_ text: String) -> ParsedSearchText {
        let characters = Array(text)
        var result = ParsedSearchText()
        var freeWords: [String] = []
        var index = 0

        while index < characters.count {
            if characters[index].isWhitespace {
                index += 1
                continue
            }
            if let (kind, afterColon) = keyword(at: index, in: characters) {
                let clauseEnd = parseClause(kind: kind, from: afterColon, in: characters, freeWords: &freeWords,
                                            result: &result, clauseStart: index)
                index = clauseEnd
                continue
            }
            // A free word.
            var end = index
            while end < characters.count, !characters[end].isWhitespace { end += 1 }
            freeWords.append(String(characters[index..<end]))
            index = end
        }
        result.freeText = freeWords.joined(separator: " ")
        return result
    }

    /// The tokens of `parse(text)` plus `tokens`, without duplicates, in order.
    static func merged(_ tokens: [SearchToken], _ parsed: [SearchToken]) -> [SearchToken] {
        var seen = Set<String>()
        var result: [SearchToken] = []
        for token in tokens + parsed where seen.insert(token.id).inserted {
            result.append(token)
        }
        return result
    }

    // MARK: Clauses

    /// `kind` and the index after its colon when a filter word starts at `index`.
    private static func keyword(at index: Int, in characters: [Character]) -> (SearchTokenKind, Int)? {
        guard index == 0 || characters[index - 1].isWhitespace else { return nil }
        for kind in SearchTokenKind.allCases {
            let word = Array(kind.keyword)
            let end = index + word.count
            guard end < characters.count, characters[end] == ":" else { continue }
            let candidate = String(characters[index..<end]).lowercased()
            if candidate == kind.keyword { return (kind, end + 1) }
        }
        return nil
    }

    /// The index of the next filter word at or after `start`, else the end.
    private static func nextKeyword(from start: Int, in characters: [Character]) -> Int {
        var index = start
        while index < characters.count {
            if (index == 0 || characters[index - 1].isWhitespace), keyword(at: index, in: characters) != nil {
                return index
            }
            index += 1
        }
        return characters.count
    }

    private static func isQuote(_ character: Character) -> Bool {
        character == "\"" || character == "“" || character == "”"
    }

    /// Parses one clause after `kind:`; returns the index where parsing continues.
    private static func parseClause(
        kind: SearchTokenKind,
        from afterColon: Int,
        in characters: [Character],
        freeWords: inout [String],
        result: inout ParsedSearchText,
        clauseStart: Int
    ) -> Int {
        var start = afterColon
        while start < characters.count, characters[start].isWhitespace { start += 1 }
        let textBefore = String(characters[0..<clauseStart]).trimmingCharacters(in: .whitespaces)

        // Quoted value: exact.
        if start < characters.count, isQuote(characters[start]) {
            var end = start + 1
            while end < characters.count, !isQuote(characters[end]) { end += 1 }
            let value = String(characters[(start + 1)..<end]).trimmingCharacters(in: .whitespaces)
            let closed = end < characters.count
            if !closed {
                // Still typing inside the quotes.
                result.trailing = SearchTrailingClause(kind: kind, partialValue: value, textBefore: textBefore)
                if kind.takesText, !value.isEmpty {
                    result.tokens.append(SearchToken(kind: kind, value: .text(value, exact: false)))
                }
                return characters.count
            }
            if let token = token(kind: kind, value: value, exact: true) {
                result.tokens.append(token)
            } else if !value.isEmpty {
                result.unresolved.append("\(kind.prefix) \(value)")
            }
            return end + 1
        }

        let regionEnd = nextKeyword(from: start, in: characters)
        let region = String(characters[start..<regionEnd])
        let reachesEnd = regionEnd == characters.count

        switch kind {
        case .artist, .album, .genre:
            let value = region.trimmingCharacters(in: .whitespaces)
            if reachesEnd {
                result.trailing = SearchTrailingClause(kind: kind, partialValue: value, textBefore: textBefore)
            }
            if !value.isEmpty {
                result.tokens.append(SearchToken(kind: kind, value: .text(value, exact: false)))
            }
        case .year, .bpm:
            let (rangeText, rest) = leadingRange(region)
            if let range = SearchNumberRange.parse(rangeText) {
                result.tokens.append(SearchToken(kind: kind, value: .range(range)))
                freeWords.append(contentsOf: rest.split(whereSeparator: \.isWhitespace).map(String.init))
                if reachesEnd, rest.trimmingCharacters(in: .whitespaces).isEmpty, region.last?.isWhitespace != true {
                    result.trailing = SearchTrailingClause(kind: kind, partialValue: rangeText, textBefore: textBefore)
                }
            } else {
                if reachesEnd {
                    result.trailing = SearchTrailingClause(
                        kind: kind, partialValue: region.trimmingCharacters(in: .whitespaces), textBefore: textBefore)
                }
                if !rangeText.isEmpty { result.unresolved.append("\(kind.prefix) \(rangeText)") }
                freeWords.append(contentsOf: rest.split(whereSeparator: \.isWhitespace).map(String.init))
            }
        case .availability:
            if let (word, rest) = leadingWord(region) {
                result.tokens.append(.availability(word))
                freeWords.append(contentsOf: rest.split(whereSeparator: \.isWhitespace).map(String.init))
                if reachesEnd, rest.trimmingCharacters(in: .whitespaces).isEmpty, region.last?.isWhitespace != true {
                    result.trailing = SearchTrailingClause(kind: kind, partialValue: word.phrase, textBefore: textBefore)
                }
            } else {
                let value = region.trimmingCharacters(in: .whitespaces)
                if reachesEnd {
                    result.trailing = SearchTrailingClause(kind: kind, partialValue: value, textBefore: textBefore)
                } else if !value.isEmpty {
                    result.unresolved.append("\(kind.prefix) \(value)")
                }
            }
        }
        return regionEnd
    }

    /// A number range at the start of `region` (`120–128`, `120 - 128`, `2019`) and the rest.
    private static func leadingRange(_ region: String) -> (String, String) {
        let trimmed = region.trimmingCharacters(in: .whitespaces)
        // `120 - 128` with spaces around the dash.
        let pattern = #/^(\d+)\s*(?:–|—|-|\.\.)\s*(\d+)/#
        if let match = trimmed.prefixMatch(of: pattern) {
            let rest = String(trimmed[match.range.upperBound...])
            return ("\(match.1)–\(match.2)", rest)
        }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let first = parts.first.map(String.init) ?? ""
        let rest = parts.count > 1 ? String(parts[1]) : ""
        return (first, rest)
    }

    /// The longest `is:` phrase at the start of `region` (whole words) and the rest.
    private static func leadingWord(_ region: String) -> (SearchAvailabilityWord, String)? {
        let trimmed = region.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        var best: (SearchAvailabilityWord, Int)?
        for word in SearchAvailabilityWord.allCases {
            for phrase in [word.phrase.lowercased()] + word.alternatePhrases {
                guard lowered.hasPrefix(phrase) else { continue }
                let after = lowered.index(lowered.startIndex, offsetBy: phrase.count)
                guard after == lowered.endIndex || lowered[after].isWhitespace else { continue }
                if best == nil || phrase.count > best!.1 { best = (word, phrase.count) }
            }
        }
        guard let (word, length) = best else { return nil }
        let rest = String(trimmed.dropFirst(length))
        return (word, rest)
    }

    /// A token for a quoted value; `nil` when the value isn't understood.
    private static func token(kind: SearchTokenKind, value: String, exact: Bool) -> SearchToken? {
        guard !value.isEmpty else { return nil }
        switch kind {
        case .artist, .album, .genre:
            return SearchToken(kind: kind, value: .text(value, exact: exact))
        case .year, .bpm:
            return SearchNumberRange.parse(value).map { SearchToken(kind: kind, value: .range($0)) }
        case .availability:
            return SearchAvailabilityWord.exact(value).map(SearchToken.availability)
        }
    }
}
