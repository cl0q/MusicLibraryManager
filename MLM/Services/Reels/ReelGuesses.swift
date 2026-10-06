import Foundation

// MARK: - Guesses with provenance (V-REELS.N06, IMP-061)

/// Where a guess came from. The word is what the list shows.
enum ReelGuessSource: String, Codable, Sendable {
    case fileName
    case shazam
    case text

    /// `File name` · `Shazam` · `Text in video` (THOUGHTS §7.14).
    var word: String {
        switch self {
        case .fileName: "File name"
        case .shazam: "Shazam"
        case .text: "Text in video"
        }
    }
}

/// One competing guess. Guesses never write the Artist/Title fields — only `Use` does.
struct ReelGuess: Codable, Equatable, Identifiable, Sendable {
    var artist: String
    var title: String
    var source: ReelGuessSource
    var confidence: Double
    /// Where in the video, in words: `matched at 0:07`, `still at 0:04`. Nil for the file name.
    var detail: String?

    var id: String { "\(source.rawValue)|\(artist.lowercased())|\(title.lowercased())" }

    /// `Fred again.. — Delilah (pull me out of this)` (the list line).
    var line: String { "\(artist) — \(title)" }

    /// The second line of the row: `Shazam · matched at 0:07`.
    var provenanceLine: String {
        guard let detail, !detail.isEmpty else { return source.word }
        return "\(source.word) · \(detail)"
    }

    static func sameSong(_ a: ReelGuess, _ b: ReelGuess) -> Bool {
        a.artist.lowercased() == b.artist.lowercased() && a.title.lowercased() == b.title.lowercased()
    }
}

/// `Artist – Title` text split by the delimiters of today's code (moved verbatim from the view).
enum ArtistTitleSplit {
    /// The file name's delimiters, including the bare `-` and `:`.
    static let fileNameDelimiters = [" - ", " – ", " — ", " • ", "•", " | ", "|", " : ", ":", "-"]

    /// `parseArtistTitle(from:)` of the old view: the first delimiter that leaves two non-empty
    /// halves; else no artist and the whole text as the title.
    static func split(_ text: String) -> (artist: String, title: String) {
        for delimiter in fileNameDelimiters {
            let parts = text.components(separatedBy: delimiter)
            if parts.count >= 2 {
                let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !artist.isEmpty && !title.isEmpty {
                    return (artist: artist, title: title)
                }
            }
        }
        return (artist: "", title: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Splittable into both halves (`Use as “Artist – Title”` is disabled otherwise).
    static func canSplit(_ text: String) -> Bool {
        let parts = split(text)
        return !parts.artist.isEmpty && !parts.title.isEmpty
    }
}

/// What Shazam found, and where.
struct ReelShazamMatch: Equatable, Sendable {
    var artist: String
    var title: String
    var offset: TimeInterval?
}

/// Merges the three kinds of guess. Pure: never writes fields (IMP-061).
enum ReelGuesses {
    /// The guess a file name gives: only when it splits into artist and title.
    static func fileNameGuess(_ fileName: String) -> ReelGuess? {
        let base = (fileName as NSString).deletingPathExtension
        let parts = ArtistTitleSplit.split(base)
        guard !parts.artist.isEmpty, !parts.title.isEmpty else { return nil }
        return ReelGuess(artist: parts.artist, title: parts.title, source: .fileName, confidence: 0.4, detail: nil)
    }

    /// Shazam first, then the `Artist – Title` text candidates in their own order, then the file
    /// name. The same song named by several sources is listed once, under the first source.
    static func merge(
        fileName: String?,
        shazam: ReelShazamMatch?,
        text: [ReelTextCandidate]
    ) -> [ReelGuess] {
        var guesses: [ReelGuess] = []
        if let shazam, !shazam.artist.isEmpty, !shazam.title.isEmpty {
            let detail = shazam.offset.map { "matched at \(timecode($0))" }
            guesses.append(ReelGuess(artist: shazam.artist, title: shazam.title, source: .shazam, confidence: 0.95, detail: detail))
        }
        for candidate in text {
            let detail = candidate.stillOffset.map { "still at \(timecode($0))" }
            let confidence = max(0.1, min(0.9, Double(candidate.score) / 100 * 0.7))
            guesses.append(ReelGuess(artist: candidate.artist, title: candidate.title, source: .text, confidence: confidence, detail: detail))
        }
        if let fileName, let guess = fileNameGuess(fileName) { guesses.append(guess) }
        var kept: [ReelGuess] = []
        for guess in guesses where !kept.contains(where: { ReelGuess.sameSong($0, guess) }) {
            kept.append(guess)
        }
        return kept
    }

    /// `0:07`, `1:02`.
    static func timecode(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: Persistence (`imported_reels.guesses_json`)

    static func encode(_ guesses: [ReelGuess]) -> String? {
        guard !guesses.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(guesses) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String?) -> [ReelGuess] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ReelGuess].self, from: data)) ?? []
    }
}
