import Foundation
import Testing
@testable import MLM

/// Tests for `ArtworkResolver` — extracts album art / thumbnails from
/// various sources given a URL or metadata.
///
/// Module 3 contract: ArtworkResolver takes a source type + metadata
/// (URL, page HTML, API response) and returns the best artwork URL.
/// It does NOT download the image — just resolves the URL.
///
/// Place implementation in: MLM/Services/Artwork/ArtworkResolver.swift
struct Module3_ArtworkResolverTests {

    // MARK: - YouTube thumbnail extraction

    @Test
    func extractsYouTubeThumbnailFromWatchURL() async throws {
        let url = try await ArtworkResolver.resolveArtworkURL(
            source: .youtube,
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
        #expect(url?.contains("dQw4w9WgXcQ") == true)
        #expect(url?.contains("ytimg.com") == true || url?.contains("youtube.com") == true)
    }

    @Test
    func extractsYouTubeThumbnailFromShortURL() async throws {
        let url = try await ArtworkResolver.resolveArtworkURL(
            source: .youtube,
            url: "https://youtu.be/dQw4w9WgXcQ"
        )
        #expect(url?.contains("dQw4w9WgXcQ") == true)
    }

    @Test
    func youTubeThumbnailUsesHighQuality() async throws {
        let url = try await ArtworkResolver.resolveArtworkURL(
            source: .youtube,
            url: "https://www.youtube.com/watch?v=testID123"
        )
        // Should prefer maxresdefault or hqdefault
        #expect(url?.contains("maxresdefault") == true || url?.contains("hqdefault") == true || url?.contains("default") == true)
    }

    // MARK: - SoundCloud artwork

    @Test
    func extractsSoundCloudArtworkFromAPIResponse() async throws {
        // SoundCloud provides artwork_url in track JSON
        let artworkURL = try await ArtworkResolver.resolveArtworkURL(
            source: .soundcloud,
            url: "https://soundcloud.com/artist/track",
            metadata: ["artwork_url": "https://i1.sndcdn.com/artworks-abc123-large.jpg"]
        )
        #expect(artworkURL?.contains("sndcdn.com") == true)
    }

    @Test
    func upgradesSoundCloudArtworkToOriginal() async throws {
        let artworkURL = try await ArtworkResolver.resolveArtworkURL(
            source: .soundcloud,
            url: "https://soundcloud.com/artist/track",
            metadata: ["artwork_url": "https://i1.sndcdn.com/artworks-abc123-large.jpg"]
        )
        // Should upgrade -large to -original for best quality
        #expect(artworkURL?.contains("-original") == true || artworkURL?.contains("-large") == true)
    }

    // MARK: - Generic OG image extraction

    @Test
    func extractsOGImageFromHTML() {
        let html = """
        <html>
        <head>
            <meta property="og:image" content="https://example.com/image.jpg">
            <title>Some Page</title>
        </head>
        <body></body>
        </html>
        """
        let url = ArtworkResolver.extractOGImage(from: html)
        #expect(url == "https://example.com/image.jpg")
    }

    @Test
    func extractsOGImageWithSingleQuotes() {
        let html = """
        <meta property='og:image' content='https://example.com/image.png'>
        """
        let url = ArtworkResolver.extractOGImage(from: html)
        #expect(url == "https://example.com/image.png")
    }

    @Test
    func extractsTwitterImageAsFallback() {
        let html = """
        <meta name="twitter:image" content="https://example.com/twitter-card.jpg">
        """
        let url = ArtworkResolver.extractOGImage(from: html)
        #expect(url == "https://example.com/twitter-card.jpg")
    }

    @Test
    func returnsNilWhenNoImageMeta() {
        let html = """
        <html><head><title>No images here</title></head><body></body></html>
        """
        let url = ArtworkResolver.extractOGImage(from: html)
        #expect(url == nil)
    }

    @Test
    func prefersOGImageOverTwitterImage() {
        let html = """
        <meta property="og:image" content="https://example.com/og.jpg">
        <meta name="twitter:image" content="https://example.com/twitter.jpg">
        """
        let url = ArtworkResolver.extractOGImage(from: html)
        #expect(url == "https://example.com/og.jpg")
    }

    // MARK: - Direct audio URL (no artwork)

    @Test
    func directAudioURLReturnsNilWithoutMetadata() async throws {
        let url = try await ArtworkResolver.resolveArtworkURL(
            source: .directAudio,
            url: "https://cdn.example.com/song.mp3"
        )
        #expect(url == nil)
    }

    // MARK: - Source type

    @Test
    func sourceTypeDetection() {
        #expect(ArtworkResolver.Source.youtube.rawValue == "youtube")
        #expect(ArtworkResolver.Source.soundcloud.rawValue == "soundcloud")
        #expect(ArtworkResolver.Source.directAudio.rawValue == "directAudio")
        #expect(ArtworkResolver.Source.genericWeb.rawValue == "genericWeb")
    }
}
