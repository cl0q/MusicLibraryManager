import Foundation

/// The current state of the universal search view.
enum UniversalSearchState: Equatable {
    case idle
    case resolving
    case searching
    case resolved(UniversalSearchResult)
    case playlistPreview
    case results
    case error(String)

    static func == (lhs: UniversalSearchState, rhs: UniversalSearchState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.resolving, .resolving), (.searching, .searching),
             (.playlistPreview, .playlistPreview), (.results, .results):
            return true
        case (.resolved(let l), .resolved(let r)):
            return l == r
        case (.error(let l), .error(let r)):
            return l == r
        default:
            return false
        }
    }
}

/// A resolved search result for a URL input.
struct UniversalSearchResult: Equatable {
    let source: ArtworkResolver.Source
    let url: String
    let title: String?
    let artist: String?
    let artworkURL: String?
    let durationSeconds: Int?
}

/// View model for the universal search view.
@Observable
final class UniversalSearchViewModel {
    var query: String = ""
    var state: UniversalSearchState = .idle

    func submit(_ input: String) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let action = UniversalSearchRouter.route(trimmed) else {
            return
        }

        switch action {
        case .downloadURL(let source, let url, let artworkURL):
            state = .resolving
            switch source {
            case .youtube:
                let videoID = URLDetector.extractYouTubeVideoID(url)
                let thumb = artworkURL
                    ?? videoID.map { "https://i.ytimg.com/vi/\($0)/maxresdefault.jpg" }
                let title = videoID.map { "YouTube Video (\($0))" } ?? "YouTube Video"
                state = .resolved(UniversalSearchResult(
                    source: source,
                    url: url,
                    title: title,
                    artist: nil,
                    artworkURL: thumb,
                    durationSeconds: nil
                ))
            case .soundcloud:
                state = .resolved(UniversalSearchResult(
                    source: source,
                    url: url,
                    title: "SoundCloud Track",
                    artist: nil,
                    artworkURL: artworkURL,
                    durationSeconds: nil
                ))
            case .directAudio:
                let filename = (url as NSString).lastPathComponent
                state = .resolved(UniversalSearchResult(
                    source: source,
                    url: url,
                    title: filename,
                    artist: nil,
                    artworkURL: nil,
                    durationSeconds: nil
                ))
            case .genericWeb:
                state = .resolved(UniversalSearchResult(
                    source: source,
                    url: url,
                    title: nil,
                    artist: nil,
                    artworkURL: nil,
                    durationSeconds: nil
                ))
            }

        case .importPlaylist:
            state = .playlistPreview

        case .fetchWebContent(let url):
            state = .resolving
            state = .resolved(UniversalSearchResult(
                source: .genericWeb,
                url: url,
                title: nil,
                artist: nil,
                artworkURL: nil,
                durationSeconds: nil
            ))

        case .searchText:
            state = .searching
        }
    }

    func clear() {
        query = ""
        state = .idle
    }
}
