import Foundation

// MARK: - A pasted link in the search field (UC-SEARCH-05, DEC-018, V-SEARCH.N14/N15)

/// A source MLM can take a link from.
enum LinkSource: String, Equatable, Sendable {
    case youtube = "YouTube"
    case soundcloud = "SoundCloud"
    case spotify = "Spotify"

    /// The `sources.name` / format word the importers use.
    var storedName: String {
        switch self {
        case .youtube: "youtube"
        case .soundcloud: "soundcloud"
        case .spotify: "spotify"
        }
    }

    var preferredDownloadSource: DownloadOrchestrator.PreferredSource {
        switch self {
        case .youtube: .youtube
        case .soundcloud: .soundcloud
        case .spotify: .auto
        }
    }
}

/// What a link resolved to (title for the suggestion row, track count for a playlist).
struct LinkMetadata: Equatable, Sendable {
    var title: String?
    var artist: String?
    var durationSeconds: Int?
    var trackCount: Int?
    var artworkURL: String?
}

/// A link typed or pasted into the search field. The text is never searched as text; the
/// field offers what can be done with it instead (`search.html` V-SEARCH.N14/N15). Pure.
enum LinkSuggestion: Equatable, Sendable {
    /// One track MLM can download (YouTube video, SoundCloud track).
    case track(source: LinkSource, url: String)
    /// A playlist / set the import takes (YouTube playlist, SoundCloud set, Spotify playlist).
    case playlist(source: LinkSource, url: String)
    /// A link MLM can't download from (another site, a single Spotify track, a file URL).
    case unsupported(host: String, url: String)

    /// The text is one `http(s)://` link with a host, nothing else.
    static func isLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// What the field offers for `text`; `nil` when it isn't a link. Uses `URLDetector`.
    static func classify(_ text: String) -> LinkSuggestion? {
        guard isLink(text) else { return nil }
        // SoundCloud links lose `?si=…`, fragments and the `www.`/`m.` host before lookup and
        // before they are stored (W3-ADD review S1, `SoundCloudLink`).
        let trimmed = SoundCloudLink.canonical(text.trimmingCharacters(in: .whitespacesAndNewlines))
        switch URLDetector.classify(trimmed) {
        case .youtubeVideo:
            return .track(source: .youtube, url: URLDetector.normalize(trimmed))
        case .youtubePlaylist:
            return .playlist(source: .youtube, url: trimmed)
        case .soundcloudTrack:
            return .track(source: .soundcloud, url: trimmed)
        case .soundcloudPlaylist:
            return .playlist(source: .soundcloud, url: trimmed)
        case .spotifyPlaylist:
            return .playlist(source: .spotify, url: trimmed)
        case .spotifyTrack, .directAudio, .genericWeb, .none:
            return .unsupported(host: host(of: trimmed), url: trimmed)
        }
    }

    var url: String {
        switch self {
        case .track(_, let url), .playlist(_, let url), .unsupported(_, let url): url
        }
    }

    var source: LinkSource? {
        switch self {
        case .track(let source, _), .playlist(let source, _): source
        case .unsupported: nil
        }
    }

    // MARK: Copy (verbatim from `search.html`)

    /// Header line: `Link · YouTube`, `Link · SoundCloud playlist`, `Link · bandcamp.com`.
    var header: String {
        switch self {
        case .track(let source, _): "Link · \(source.rawValue)"
        case .playlist(let source, _): "Link · \(source.rawValue) playlist"
        case .unsupported(let host, _): "Link · \(host)"
        }
    }

    /// The row's action: `Download track from YouTube — “‹title›”` /
    /// `Import playlist from SoundCloud… (44 tracks)`; without metadata the title is left out.
    func actionTitle(_ metadata: LinkMetadata?) -> String {
        switch self {
        case .track(let source, _):
            let base = "Download track from \(source.rawValue)"
            guard let title = metadata?.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return base }
            return "\(base) — “\(title)”"
        case .playlist(let source, _):
            let base = "Import playlist from \(source.rawValue)…"
            guard let count = metadata?.trackCount else { return base }
            return "\(base) (\(count.formatted(.number)) \(count == 1 ? "track" : "tracks"))"
        case .unsupported:
            return Self.unsupportedLine
        }
    }

    /// The second line: `youtube.com/watch?v=… · 3:42` (track) or `“‹title›”` (playlist).
    func detail(_ metadata: LinkMetadata?) -> String {
        switch self {
        case .track(_, let url):
            var parts = [Self.shortURL(url)]
            if let seconds = metadata?.durationSeconds { parts.append(Self.time(seconds)) }
            return parts.joined(separator: " · ")
        case .playlist(_, let url):
            if let title = metadata?.title, !title.isEmpty {
                if let owner = metadata?.artist, !owner.isEmpty { return "“\(title)” by \(owner)" }
                return "“\(title)”"
            }
            return Self.shortURL(url)
        case .unsupported(_, let url):
            return Self.shortURL(url)
        }
    }

    /// `Already in your library — “‹title›”`.
    static func inLibraryTitle(_ title: String) -> String { "Already in your library — “\(title)”" }
    static let inLibraryDetail = "Show in All Tracks"
    static let lookingUp = "Looking up the link…"
    static let unsupportedLine = "MLM can’t download from this site"
    static let openInBrowser = "Open in Browser"

    /// `youtube.com/watch?v=Zx3kQpL0v9E` — without scheme and `www.`.
    static func shortURL(_ url: String) -> String {
        var text = url
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.lowercased().hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text
    }

    static func host(of url: String) -> String {
        guard let host = URL(string: url)?.host?.lowercased() else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// `3:42`, `1:02:14` (UC-COPY-10).
    static func time(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
