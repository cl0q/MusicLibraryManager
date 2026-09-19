import Foundation
import Testing
@testable import MLM

/// Tests for `UniversalSearchRouter` — the backend logic that takes user input
/// from the universal search bar, classifies it (URL vs text), and produces
/// a resolved action with artwork.
///
/// Module 4 contract: UniversalSearchRouter integrates URLDetector and
/// ArtworkResolver to produce a typed search action that the UI can execute.
///
/// Place implementation in: MLM/Services/Search/UniversalSearchRouter.swift
struct Module4_UniversalSearchRouterTests {

    // MARK: - Input classification

    @Test
    func routesYouTubeVideoURL() {
        let action = UniversalSearchRouter.route("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        switch action {
        case .downloadURL(let source, let url, let artworkURL):
            #expect(source == .youtube)
            #expect(url.contains("youtube.com"))
            // Should have resolved artwork
            #expect(artworkURL?.contains("ytimg.com") == true)
        default:
            Issue.record("Expected .downloadURL for YouTube video URL")
        }
    }

    @Test
    func routesYouTubeVideoURLWithTimestamp() {
        let action = UniversalSearchRouter.route("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")
        switch action {
        case .downloadURL(let source, let url, _):
            #expect(source == .youtube)
            // Timestamp should be stripped from the URL
            #expect(!url.contains("t=42s"))
        default:
            Issue.record("Expected .downloadURL for YouTube video URL with timestamp")
        }
    }

    @Test
    func routesYouTubePlaylistURL() {
        let action = UniversalSearchRouter.route("https://www.youtube.com/playlist?list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf")
        switch action {
        case .importPlaylist(let source, let url):
            #expect(source == .youtube)
            #expect(url.contains("playlist"))
        default:
            Issue.record("Expected .importPlaylist for YouTube playlist URL")
        }
    }

    @Test
    func routesSoundCloudTrackURL() {
        let action = UniversalSearchRouter.route("https://soundcloud.com/artist/track-name")
        switch action {
        case .downloadURL(let source, let url, _):
            #expect(source == .soundcloud)
            #expect(url.contains("soundcloud.com"))
        default:
            Issue.record("Expected .downloadURL for SoundCloud track URL")
        }
    }

    @Test
    func routesSoundCloudPlaylistURL() {
        let action = UniversalSearchRouter.route("https://soundcloud.com/artist/sets/playlist-name")
        switch action {
        case .importPlaylist(let source, let url):
            #expect(source == .soundcloud)
            #expect(url.contains("sets"))
        default:
            Issue.record("Expected .importPlaylist for SoundCloud playlist URL")
        }
    }

    @Test
    func routesDirectAudioURL() {
        let action = UniversalSearchRouter.route("https://cdn.example.com/audio/song.mp3")
        switch action {
        case .downloadURL(let source, let url, _):
            #expect(source == .directAudio)
            #expect(url.contains(".mp3"))
        default:
            Issue.record("Expected .downloadURL for direct audio URL")
        }
    }

    @Test
    func routesGenericWebURL() {
        let action = UniversalSearchRouter.route("https://www.someblog.com/post/cool-music")
        switch action {
        case .fetchWebContent(let url):
            #expect(url.contains("someblog.com"))
        default:
            Issue.record("Expected .fetchWebContent for generic web URL")
        }
    }

    @Test
    func routesPlainTextAsSearch() {
        let action = UniversalSearchRouter.route("kanye west run away")
        switch action {
        case .searchText(let query):
            #expect(query == "kanye west run away")
        default:
            Issue.record("Expected .searchText for plain text input")
        }
    }

    @Test
    func trimsWhitespace() {
        let action = UniversalSearchRouter.route("  kanye west  ")
        switch action {
        case .searchText(let query):
            #expect(query == "kanye west")
        default:
            Issue.record("Expected .searchText with trimmed query")
        }
    }

    @Test
    func emptyInputReturnsNil() {
        let action = UniversalSearchRouter.route("")
        #expect(action == nil)
    }

    @Test
    func whitespaceOnlyReturnsNil() {
        let action = UniversalSearchRouter.route("   ")
        #expect(action == nil)
    }

    // MARK: - Spotify routing

    @Test
    func routesSpotifyTrackURL() {
        let action = UniversalSearchRouter.route("https://open.spotify.com/track/6rqhFgbbKwnb9MLmUQDhG6")
        switch action {
        case .searchText(let query):
            // Spotify URLs should be treated as search text (we can't download from Spotify)
            #expect(query.contains("spotify") || query.contains("track"))
        default:
            // Also acceptable as a recognized but non-downloadable source
            break
        }
    }

    // MARK: - Normalization

    @Test
    func normalizesURLBeforeRouting() {
        // YouTube URL with timestamp should be normalized
        let action = UniversalSearchRouter.route("https://youtu.be/abc123?t=300")
        switch action {
        case .downloadURL(_, let url, _):
            #expect(!url.contains("t=300"))
        default:
            Issue.record("Expected normalized URL without timestamp")
        }
    }
}
