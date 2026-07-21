import Foundation
import Testing
@testable import MLM

/// Tests for `YouTubeDownloader.normalizeQueryForYouTube`.
///
/// SCDL-03: identity-bearing qualifiers (remix, edit, version, live,
/// slowed, bootleg, remaster, ...) must survive query normalization,
/// while non-identity noise ("Official Music Video", "feat. X") must
/// still be stripped. This is a pure static function — no I/O, no
/// subprocess invocation — so it is tested directly and exhaustively.
struct YouTubeDownloaderTests {

    @Test
    func preservesRemixQualifier() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Kanye West - Bound 2 (Remix)")
        #expect(result.lowercased().contains("remix"))
    }

    @Test
    func preservesEditQualifier() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (Extended Edit)")
        #expect(result.lowercased().contains("edit"))
    }

    @Test
    func preservesSlowedQualifier() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (Slowed + Reverb)")
        #expect(result.lowercased().contains("slowed"))
    }

    @Test
    func preservesLiveQualifier() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (Live at Wembley)")
        #expect(result.lowercased().contains("live"))
    }

    @Test
    func preservesBootlegQualifier() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (Bootleg)")
        #expect(result.lowercased().contains("bootleg"))
    }

    @Test
    func preservesRemasterQualifierYearPrefixed() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (2024 Remaster)")
        #expect(result.lowercased().contains("remaster"))
    }

    @Test
    func preservesRemasteredQualifier() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (Remastered)")
        #expect(result.lowercased().contains("remaster"))
    }

    @Test
    func stripsOfficialMusicVideoNoise() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (Official Music Video)")
        #expect(!result.lowercased().contains("official"))
        #expect(!result.lowercased().contains("video"))
    }

    @Test
    func stripsOfficialVideoBracketNoise() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title [Official Video]")
        #expect(!result.lowercased().contains("official"))
        #expect(!result.lowercased().contains("video"))
    }

    @Test
    func stripsFeaturingNoise() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (feat. X)")
        #expect(!result.lowercased().contains("feat"))
    }

    @Test
    func caseInsensitiveMatching() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (REMIX)")
        #expect(result.lowercased().contains("remix"))
    }

    @Test
    func plainTitleUnaffected() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title")
        #expect(result == "Artist - Title")
    }
}
