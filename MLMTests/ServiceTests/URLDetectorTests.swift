import Foundation
import Testing
@testable import MLM

/// Tests for `URLDetector` — pure URL classification and normalization.
///
/// Module 1 contract: URLDetector is a static/utility type that classifies
/// pasted URLs into source types and normalizes them (stripping tracking
/// params like YouTube's ?t= timestamp). No I/O, no network, no subprocess.
///
/// Place implementation in: MLM/Services/Search/URLDetector.swift
struct Module1_URLDetectorTests {

    // MARK: - Classification

    @Test
    func classifiesYouTubeVideoURL() {
        let result = URLDetector.classify("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(result == .youtubeVideo)
    }

    @Test
    func classifiesYouTubeVideoURLWithTimestamp() {
        let result = URLDetector.classify("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")
        #expect(result == .youtubeVideo)
    }

    @Test
    func classifiesYouTubeShortURL() {
        let result = URLDetector.classify("https://youtu.be/dQw4w9WgXcQ")
        #expect(result == .youtubeVideo)
    }

    @Test
    func classifiesYouTubeShortURLWithTimestamp() {
        let result = URLDetector.classify("https://youtu.be/dQw4w9WgXcQ?t=123")
        #expect(result == .youtubeVideo)
    }

    @Test
    func classifiesYouTubePlaylistURL() {
        let result = URLDetector.classify("https://www.youtube.com/playlist?list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf")
        #expect(result == .youtubePlaylist)
    }

    @Test
    func classifiesYouTubeMusicURL() {
        let result = URLDetector.classify("https://music.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(result == .youtubeVideo)
    }

    @Test
    func classifiesSoundCloudTrackURL() {
        let result = URLDetector.classify("https://soundcloud.com/artist/track-name")
        #expect(result == .soundcloudTrack)
    }

    @Test
    func classifiesSoundCloudPlaylistURL() {
        let result = URLDetector.classify("https://soundcloud.com/artist/sets/playlist-name")
        #expect(result == .soundcloudPlaylist)
    }

    @Test
    func classifiesSoundCloudPlaylistURLWithQueryParams() {
        let result = URLDetector.classify("https://soundcloud.com/artist/sets/playlist-name?si=abc123")
        #expect(result == .soundcloudPlaylist)
    }

    @Test
    func classifiesDirectAudioURL_mp3() {
        let result = URLDetector.classify("https://cdn.example.com/audio/song.mp3")
        #expect(result == .directAudio)
    }

    @Test
    func classifiesDirectAudioURL_m4a() {
        let result = URLDetector.classify("https://cdn.example.com/audio/song.m4a")
        #expect(result == .directAudio)
    }

    @Test
    func classifiesDirectAudioURL_flac() {
        let result = URLDetector.classify("https://cdn.example.com/audio/song.flac")
        #expect(result == .directAudio)
    }

    @Test
    func classifiesDirectAudioURL_wav() {
        let result = URLDetector.classify("https://cdn.example.com/audio/song.wav")
        #expect(result == .directAudio)
    }

    @Test
    func classifiesDirectAudioURL_ogg() {
        let result = URLDetector.classify("https://cdn.example.com/audio/song.ogg")
        #expect(result == .directAudio)
    }

    @Test
    func classifiesDirectAudioURL_withQueryParams() {
        let result = URLDetector.classify("https://cdn.example.com/audio/song.mp3?token=abc&expires=123")
        #expect(result == .directAudio)
    }

    @Test
    func classifiesGenericWebURL() {
        let result = URLDetector.classify("https://www.someblog.com/post/cool-music")
        #expect(result == .genericWeb)
    }

    @Test
    func classifiesNonURLAsNone() {
        let result = URLDetector.classify("some random search text")
        #expect(result == .none)
    }

    @Test
    func classifiesEmptyStringAsNone() {
        let result = URLDetector.classify("")
        #expect(result == .none)
    }

    @Test
    func classifiesPartialURLAsNone() {
        let result = URLDetector.classify("youtube.com")
        #expect(result == .none)
    }

    @Test
    func classifiesSpotifyTrackURL() {
        let result = URLDetector.classify("https://open.spotify.com/track/6rqhFgbbKwnb9MLmUQDhG6")
        #expect(result == .spotifyTrack)
    }

    @Test
    func classifiesSpotifyPlaylistURL() {
        let result = URLDetector.classify("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")
        #expect(result == .spotifyPlaylist)
    }

    // MARK: - Normalization

    @Test
    func stripsYouTubeTimestamp_watch() {
        let normalized = URLDetector.normalize("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")
        #expect(normalized == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test
    func stripsYouTubeTimestamp_shortURL() {
        let normalized = URLDetector.normalize("https://youtu.be/dQw4w9WgXcQ?t=123")
        #expect(normalized == "https://youtu.be/dQw4w9WgXcQ")
    }

    @Test
    func stripsYouTubeTimestamp_integerSeconds() {
        let normalized = URLDetector.normalize("https://www.youtube.com/watch?v=abc123&t=3600")
        #expect(normalized == "https://www.youtube.com/watch?v=abc123")
    }

    @Test
    func stripsYouTubeTimestampWithOtherParams() {
        let normalized = URLDetector.normalize("https://www.youtube.com/watch?v=abc123&feature=share&t=42s")
        // Should strip t= but keep other params
        #expect(normalized.contains("v=abc123"))
        #expect(!normalized.contains("t=42s"))
    }

    @Test
    func preservesNonYouTubeURLs() {
        let url = "https://soundcloud.com/artist/track?si=abc123"
        let normalized = URLDetector.normalize(url)
        #expect(normalized == url)
    }

    @Test
    func normalizesYouTubeMusicURL() {
        let normalized = URLDetector.normalize("https://music.youtube.com/watch?v=abc&t=30s")
        #expect(normalized == "https://music.youtube.com/watch?v=abc")
    }

    @Test
    func returnsOriginalForNonURL() {
        let normalized = URLDetector.normalize("just some text")
        #expect(normalized == "just some text")
    }

    // MARK: - Video ID extraction

    @Test
    func extractsVideoIDFromWatchURL() {
        let id = URLDetector.extractYouTubeVideoID("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(id == "dQw4w9WgXcQ")
    }

    @Test
    func extractsVideoIDFromShortURL() {
        let id = URLDetector.extractYouTubeVideoID("https://youtu.be/dQw4w9WgXcQ")
        #expect(id == "dQw4w9WgXcQ")
    }

    @Test
    func extractsVideoIDStripsTimestamp() {
        let id = URLDetector.extractYouTubeVideoID("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")
        #expect(id == "dQw4w9WgXcQ")
    }

    @Test
    func returnsNilForNonYouTubeURL() {
        let id = URLDetector.extractYouTubeVideoID("https://soundcloud.com/artist/track")
        #expect(id == nil)
    }

    @Test
    func returnsNilForPlaylistURL() {
        let id = URLDetector.extractYouTubeVideoID("https://www.youtube.com/playlist?list=PLabc123")
        #expect(id == nil)
    }

    // MARK: - Playlist ID extraction

    @Test
    func extractsPlaylistID() {
        let id = URLDetector.extractYouTubePlaylistID("https://www.youtube.com/playlist?list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf")
        #expect(id == "PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf")
    }

    @Test
    func returnsNilForNonPlaylistURL() {
        let id = URLDetector.extractYouTubePlaylistID("https://www.youtube.com/watch?v=abc")
        #expect(id == nil)
    }
}
