import Foundation

enum DetectedURLSource: String, Equatable, Sendable {
    case youtubeVideo
    case youtubePlaylist
    case soundcloudTrack
    case soundcloudPlaylist
    case spotifyTrack
    case spotifyPlaylist
    case directAudio
    case genericWeb
    case none
}

enum URLDetector {

    // MARK: - Classification

    static func classify(_ input: String) -> DetectedURLSource {
        guard let url = URL(string: input), let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            return .none
        }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()

        // YouTube
        if host.contains("youtube.com") || host == "youtu.be" {
            if host.contains("youtube.com") && path == "/playlist" {
                let components = URLComponents(string: input)
                if let queryItems = components?.queryItems,
                   queryItems.contains(where: { $0.name == "list" }) {
                    return .youtubePlaylist
                }
            }
            // /watch?v= or youtu.be/ID
            if path == "/watch" || host == "youtu.be" {
                return .youtubeVideo
            }
            // music.youtube.com/watch etc.
            if path == "/watch" {
                return .youtubeVideo
            }
        }

        // SoundCloud
        if host == "soundcloud.com" {
            if path.contains("/sets/") {
                return .soundcloudPlaylist
            }
            return .soundcloudTrack
        }

        // Spotify
        if host == "open.spotify.com" {
            if path.hasPrefix("/track/") {
                return .spotifyTrack
            }
            if path.hasPrefix("/playlist/") {
                return .spotifyPlaylist
            }
        }

        // Direct audio by path extension
        let audioExtensions: Set<String> = ["mp3", "m4a", "flac", "wav", "ogg", "aac", "wma", "opus"]
        let pathExtension = (url.path as NSString).pathExtension.lowercased()
        if audioExtensions.contains(pathExtension) {
            return .directAudio
        }

        return .genericWeb
    }

    // MARK: - Normalization

    static func normalize(_ input: String) -> String {
        guard let url = URL(string: input),
              let host = url.host?.lowercased(),
              (host.contains("youtube.com") || host == "youtu.be") else {
            return input
        }

        guard var components = URLComponents(string: input) else {
            return input
        }

        if let queryItems = components.queryItems {
            let filtered = queryItems.filter { $0.name != "t" }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }

        return components.string ?? input
    }

    // MARK: - Video ID extraction

    static func extractYouTubeVideoID(_ url: String) -> String? {
        guard let parsed = URL(string: url),
              let host = parsed.host?.lowercased() else {
            return nil
        }

        let isYouTube = host.contains("youtube.com") || host == "youtu.be"
        guard isYouTube else { return nil }

        let path = parsed.path.lowercased()

        // Playlist URLs don't have a video ID
        if path == "/playlist" { return nil }

        if host == "youtu.be" {
            // youtu.be/VIDEO_ID
            let id = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }

        // youtube.com/watch?v=VIDEO_ID
        if path == "/watch" {
            guard let components = URLComponents(string: url),
                  let queryItems = components.queryItems,
                  let vItem = queryItems.first(where: { $0.name == "v" }),
                  let value = vItem.value, !value.isEmpty else {
                return nil
            }
            return value
        }

        return nil
    }

    // MARK: - Playlist ID extraction

    static func extractYouTubePlaylistID(_ url: String) -> String? {
        guard let parsed = URL(string: url),
              let host = parsed.host?.lowercased(),
              host.contains("youtube.com") else {
            return nil
        }

        let path = parsed.path.lowercased()
        guard path == "/playlist" else { return nil }

        guard let components = URLComponents(string: url),
              let queryItems = components.queryItems,
              let listItem = queryItems.first(where: { $0.name == "list" }),
              let value = listItem.value, !value.isEmpty else {
            return nil
        }

        return value
    }
}
