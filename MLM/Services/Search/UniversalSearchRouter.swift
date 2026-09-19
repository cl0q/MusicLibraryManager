import Foundation

/// The action the UI should take for a universal search input.
enum UniversalSearchAction: Equatable {
    /// Download a single track from a URL (YouTube video, SC track, direct audio).
    /// Includes resolved artwork URL if available.
    case downloadURL(source: ArtworkResolver.Source, url: String, artworkURL: String?)
    /// Import a playlist (YouTube playlist, SC playlist).
    case importPlaylist(source: ArtworkResolver.Source, url: String)
    /// Fetch and parse generic web content to find downloadable audio.
    case fetchWebContent(url: String)
    /// Plain text search across sources.
    case searchText(query: String)

    static func == (lhs: UniversalSearchAction, rhs: UniversalSearchAction) -> Bool {
        switch (lhs, rhs) {
        case (.downloadURL(let ls, let lu, let la), .downloadURL(let rs, let ru, let ra)):
            return ls == rs && lu == ru && la == ra
        case (.importPlaylist(let ls, let lu), .importPlaylist(let rs, let ru)):
            return ls == rs && lu == ru
        case (.fetchWebContent(let l), .fetchWebContent(let r)):
            return l == r
        case (.searchText(let l), .searchText(let r)):
            return l == r
        default:
            return false
        }
    }
}

/// Routes universal search input to the appropriate action.
enum UniversalSearchRouter {
    static func route(_ input: String) -> UniversalSearchAction? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let source = URLDetector.classify(trimmed)

        switch source {
        case .youtubeVideo:
            let normalized = URLDetector.normalize(trimmed)
            var artworkURL: String?
            if let videoID = URLDetector.extractYouTubeVideoID(normalized) {
                artworkURL = "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg"
            }
            return .downloadURL(source: .youtube, url: normalized, artworkURL: artworkURL)

        case .youtubePlaylist:
            return .importPlaylist(source: .youtube, url: trimmed)

        case .soundcloudTrack:
            return .downloadURL(source: .soundcloud, url: trimmed, artworkURL: nil)

        case .soundcloudPlaylist:
            return .importPlaylist(source: .soundcloud, url: trimmed)

        case .directAudio:
            return .downloadURL(source: .directAudio, url: trimmed, artworkURL: nil)

        case .genericWeb:
            return .fetchWebContent(url: trimmed)

        case .spotifyTrack, .spotifyPlaylist:
            return .searchText(query: trimmed)

        case .none:
            return .searchText(query: trimmed)
        }
    }
}
