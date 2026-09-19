import Foundation
import Testing
@testable import MLM

/// Tests for `WebContentFetcher` — fetches a web page and extracts
/// audio CDN links and OG metadata. Filters out ad domains.
///
/// Module 5 contract: WebContentFetcher takes raw HTML (or a URL to fetch)
/// and returns structured content: title, description, artwork URL, and
/// a list of audio URLs found in the page.
///
/// Place implementation in: MLM/Services/Search/WebContentFetcher.swift
struct Module5_WebContentFetcherTests {

    // MARK: - Audio URL extraction from HTML

    @Test
    func extractsAudioSrcFromAudioTag() {
        let html = """
        <html><body>
        <audio src="https://cdn.example.com/track.mp3"></audio>
        </body></html>
        """
        let result = WebContentFetcher.extractAudioURLs(from: html)
        #expect(result.contains("https://cdn.example.com/track.mp3"))
    }

    @Test
    func extractsAudioSrcFromSourceTag() {
        let html = """
        <audio>
            <source src="https://cdn.example.com/track.ogg" type="audio/ogg">
            <source src="https://cdn.example.com/track.mp3" type="audio/mpeg">
        </audio>
        """
        let result = WebContentFetcher.extractAudioURLs(from: html)
        #expect(result.count >= 2)
        #expect(result.contains("https://cdn.example.com/track.ogg"))
        #expect(result.contains("https://cdn.example.com/track.mp3"))
    }

    @Test
    func extractsVideoSrcAsAudioFallback() {
        let html = """
        <video src="https://cdn.example.com/video-with-music.mp4"></video>
        """
        let result = WebContentFetcher.extractAudioURLs(from: html)
        #expect(result.contains("https://cdn.example.com/video-with-music.mp4"))
    }

    @Test
    func extractsDirectAudioLinksFromPage() {
        let html = """
        <a href="https://cdn.example.com/song.flac">Download</a>
        <a href="https://cdn.example.com/song2.m4a">Download 2</a>
        """
        let result = WebContentFetcher.extractAudioURLs(from: html)
        #expect(result.contains("https://cdn.example.com/song.flac"))
        #expect(result.contains("https://cdn.example.com/song2.m4a"))
    }

    @Test
    func filtersOutAdDomains() {
        let html = """
        <audio src="https://cdn.example.com/track.mp3"></audio>
        <audio src="https://ads.doubleclick.net/ad-track.mp3"></audio>
        <a href="https://cdn.example.com/song.mp3">DL</a>
        <a href="https://adserver.example.com/jingle.mp3">Ad</a>
        """
        let result = WebContentFetcher.extractAudioURLs(from: html)
        #expect(result.contains("https://cdn.example.com/track.mp3"))
        #expect(result.contains("https://cdn.example.com/song.mp3"))
        #expect(!result.contains { $0.contains("doubleclick") })
        #expect(!result.contains { $0.contains("adserver") })
    }

    @Test
    func filtersOutTrackingParams() {
        let html = """
        <audio src="https://cdn.example.com/track.mp3?utm_source=ads&utm_medium=banner"></audio>
        """
        let result = WebContentFetcher.extractAudioURLs(from: html)
        // Should either filter this out or strip tracking params
        // The URL should not contain utm_ params
        for url in result {
            #expect(!url.contains("utm_source"))
        }
    }

    @Test
    func deduplicatesURLs() {
        let html = """
        <audio src="https://cdn.example.com/track.mp3"></audio>
        <a href="https://cdn.example.com/track.mp3">Download</a>
        """
        let result = WebContentFetcher.extractAudioURLs(from: html)
        let unique = Set(result)
        #expect(result.count == unique.count)
    }

    @Test
    func returnsEmptyForNoAudio() {
        let html = """
        <html><body><p>No audio here, just text.</p></body></html>
        """
        let result = WebContentFetcher.extractAudioURLs(from: html)
        #expect(result.isEmpty)
    }

    // MARK: - OG metadata extraction

    @Test
    func extractsOGTitle() {
        let html = """
        <meta property="og:title" content="Cool Song Name">
        """
        let meta = WebContentFetcher.extractMetadata(from: html)
        #expect(meta.title == "Cool Song Name")
    }

    @Test
    func extractsOGDescription() {
        let html = """
        <meta property="og:description" content="A great track by Artist">
        """
        let meta = WebContentFetcher.extractMetadata(from: html)
        #expect(meta.description == "A great track by Artist")
    }

    @Test
    func extractsOGImage() {
        let html = """
        <meta property="og:image" content="https://example.com/cover.jpg">
        """
        let meta = WebContentFetcher.extractMetadata(from: html)
        #expect(meta.imageURL == "https://example.com/cover.jpg")
    }

    @Test
    func fallsBackToTitleTag() {
        let html = """
        <html><head><title>Page Title Here</title></head><body></body></html>
        """
        let meta = WebContentFetcher.extractMetadata(from: html)
        #expect(meta.title == "Page Title Here")
    }

    @Test
    func handlesEmptyHTML() {
        let meta = WebContentFetcher.extractMetadata(from: "")
        #expect(meta.title == nil)
        #expect(meta.description == nil)
        #expect(meta.imageURL == nil)
    }

    // MARK: - Audio file extension detection

    @Test
    func recognizesAudioExtensions() {
        #expect(WebContentFetcher.isAudioURL("https://cdn.com/song.mp3"))
        #expect(WebContentFetcher.isAudioURL("https://cdn.com/song.m4a"))
        #expect(WebContentFetcher.isAudioURL("https://cdn.com/song.flac"))
        #expect(WebContentFetcher.isAudioURL("https://cdn.com/song.wav"))
        #expect(WebContentFetcher.isAudioURL("https://cdn.com/song.ogg"))
        #expect(WebContentFetcher.isAudioURL("https://cdn.com/song.aac"))
        #expect(WebContentFetcher.isAudioURL("https://cdn.com/song.opus"))
        #expect(!WebContentFetcher.isAudioURL("https://cdn.com/page.html"))
        #expect(!WebContentFetcher.isAudioURL("https://cdn.com/image.jpg"))
    }

    @Test
    func isAudioURLIgnoresQueryParams() {
        #expect(WebContentFetcher.isAudioURL("https://cdn.com/song.mp3?token=abc"))
    }
}
