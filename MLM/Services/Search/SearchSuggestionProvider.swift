import Foundation

// MARK: - What the field looks up while typing (V-SEARCH.N14–N17)

/// What a pasted link turned out to be: its metadata and whether the library has it.
struct LinkLookup: Equatable, Sendable {
    var metadata: LinkMetadata?
    /// The library track the link already is (`Already in your library — “‹title›”`).
    var libraryTrackID: Int64?
}

/// The lookups behind the suggestions: token values from the library (`DISTINCT` queries,
/// capped) and what a pasted link is. Reads only. Faked in tests (no network).
protocol SearchSuggestionProviding: Sendable {
    func values(kind: SearchTokenKind, partial: String) async -> [SearchValueSuggestion]
    func lookUp(_ link: LinkSuggestion) async -> LinkLookup
}

/// The app's provider: the open library's `TrackSearchQueries` and yt-dlp for link metadata
/// (YouTube and SoundCloud; it never downloads here).
struct LiveSearchSuggestionProvider: SearchSuggestionProviding {
    let queries: @MainActor @Sendable () -> TrackSearchQueries?

    init(queries: @escaping @MainActor @Sendable () -> TrackSearchQueries? = { TrackSearchQueries.current() }) {
        self.queries = queries
    }

    func values(kind: SearchTokenKind, partial: String) async -> [SearchValueSuggestion] {
        guard let queries = await queries() else { return [] }
        return (try? await queries.valueSuggestions(kind: kind, partial: partial)) ?? []
    }

    func lookUp(_ link: LinkSuggestion) async -> LinkLookup {
        var lookup = LinkLookup()
        if case .track = link, let queries = await queries() {
            lookup.libraryTrackID = try? await queries.trackID(forLink: link.url)
        }
        switch link {
        case .track(let source, let url), .playlist(let source, let url):
            guard source != .spotify else { return lookup }
            let downloader = YouTubeDownloader()
            guard downloader.isAvailable, let entries = try? await downloader.fetchURLInfo(url: url) else { return lookup }
            if case .playlist = link {
                lookup.metadata = LinkMetadata(trackCount: entries.count)
            } else if let entry = entries.first {
                lookup.metadata = LinkMetadata(
                    title: entry.title,
                    artist: entry.uploader,
                    durationSeconds: entry.durationSeconds,
                    artworkURL: URLDetector.extractYouTubeVideoID(url).map { "https://i.ytimg.com/vi/\($0)/maxresdefault.jpg" }
                )
            }
        case .unsupported:
            break
        }
        return lookup
    }
}
