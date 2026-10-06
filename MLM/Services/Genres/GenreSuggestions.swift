import Foundation

// MARK: - Suggested tracks (V-GENRED.N04, ST-STUDIO-GENRE)

/// The suggestion controls (ST-STUDIO-GENRE.E03): `Temperature 0.0–1.0` became three words,
/// `10 / 20` stays, `Only tracks without a genre` is on by default so a save never silently
/// overwrites a genre. Remembered between sessions.
struct GenreSuggestionOptions: Equatable, Codable, Sendable {
    enum Match: String, CaseIterable, Codable, Sendable, Identifiable {
        case close, balanced, wide

        var id: String { rawValue }

        var title: String {
            switch self {
            case .close: "Close"
            case .balanced: "Balanced"
            case .wide: "Wide"
            }
        }

        /// The randomness of the existing similarity ranking (`fetchSimilarTracks`).
        var temperature: Double {
            switch self {
            case .close: 0
            case .balanced: 0.1
            case .wide: 0.3
            }
        }

        /// The lowest match shown (`Close` = only near matches).
        var minimumPercent: Int {
            switch self {
            case .close: 84
            case .balanced: 68
            case .wide: 0
            }
        }
    }

    var match: Match = .balanced
    /// 10 or 20.
    var count: Int = 10
    var onlyTracksWithoutGenre = true

    static let countChoices = [10, 20]

    private static let defaultsKey = "genres.suggestionOptions"

    static func load(_ defaults: UserDefaults = .standard) -> GenreSuggestionOptions {
        guard let data = defaults.data(forKey: defaultsKey),
              var options = try? JSONDecoder().decode(GenreSuggestionOptions.self, from: data) else { return .init() }
        if !countChoices.contains(options.count) { options.count = 10 }
        return options
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// One suggested track and how close it sounds to the reference (`93 %`).
struct GenreSuggestion: Identifiable, Equatable, Sendable {
    let track: Track
    let matchPercent: Int

    var id: Int64 { track.id ?? -1 }
}

/// A similarity candidate from the existing ranking (`TrackRepository.fetchSimilarTracks`).
struct GenreSimilarityCandidate: Sendable {
    let track: Track
    /// 0…1.
    let score: Float
}

/// Where candidates come from — the live one asks `TrackRepository.fetchSimilarTracks` (the
/// logic the old genre tools used, ST-STUDIO-GENRE); tests hand in their own.
struct GenreSimilaritySource: Sendable {
    let similar: @Sendable (_ seedID: Int64, _ limit: Int, _ temperature: Double) async throws -> [GenreSimilarityCandidate]

    @MainActor
    static func live(_ container: DependencyContainer = .shared) -> GenreSimilaritySource? {
        guard let tracks = container.trackRepository else { return nil }
        let repository = UncheckedSendableBox(tracks)
        return GenreSimilaritySource { seed, limit, temperature in
            try await repository.value.fetchSimilarTracks(seedTrackId: seed, limit: limit, temperature: temperature)
                .map { GenreSimilarityCandidate(track: $0.track, score: $0.score) }
        }
    }
}

/// Holds a non-`Sendable` reference whose use is safe (the repository serialises through GRDB).
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

enum GenreSuggestionRules {
    /// How many candidates to ask for: the shown count plus room for the ones filtered out.
    static func requestLimit(_ options: GenreSuggestionOptions) -> Int {
        options.count * 4 + 40
    }

    /// The rows the section shows: candidates not in the genre, not hidden this session, not
    /// already staged (staged rows are listed first by the caller), matching the options,
    /// best first, at most `options.count`.
    static func pick(
        _ candidates: [GenreSimilarityCandidate],
        genreKey: String,
        options: GenreSuggestionOptions,
        hidden: Set<Int64>,
        staged: Set<Int64>,
        reference: Int64?
    ) -> [GenreSuggestion] {
        var seen = Set<Int64>()
        var result: [GenreSuggestion] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard let id = candidate.track.id, id != reference, seen.insert(id).inserted else { continue }
            guard !hidden.contains(id), !staged.contains(id) else { continue }
            let key = GenreName.key(candidate.track.genre)
            if key == genreKey { continue }
            if options.onlyTracksWithoutGenre, key != nil { continue }
            let percent = Int((Double(candidate.score) * 100).rounded())
            guard percent >= options.match.minimumPercent else { continue }
            result.append(GenreSuggestion(track: candidate.track, matchPercent: percent))
            if result.count == options.count { break }
        }
        return result
    }
}
