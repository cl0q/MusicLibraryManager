import Foundation
import Testing
@testable import MLM

/// Tests for DAB result matching logic.
///
/// Backs documented invariant #1: a DAB hit must match BOTH artist AND
/// title before the chain accepts it. Without the artist check, the
/// pipeline silently downloads wrong-artist covers at high quality.
struct DABMatchingTests {

    // MARK: - Title matches

    @Test func titleExactMatch() {
        #expect(DABMatcher.titleMatches("Oxycodone", requested: "Oxycodone"))
    }

    @Test func titleCaseInsensitive() {
        #expect(DABMatcher.titleMatches("oxycodone", requested: "Oxycodone"))
        #expect(DABMatcher.titleMatches("OXYCODONE", requested: "oxycodone"))
    }

    @Test func titleFeatTagIsIgnored() {
        // Common SoundCloud / streaming pattern.
        #expect(DABMatcher.titleMatches("Oxycodone (feat. Someone)", requested: "Oxycodone"))
    }

    @Test func titleRequestedContainsDabResult() {
        // Reverse direction also matches (one contains the other).
        #expect(DABMatcher.titleMatches("Oxycodone", requested: "Oxycodone Remix"))
    }

    @Test func titleDoesNotMatchUnrelatedTrack() {
        #expect(!DABMatcher.titleMatches("Perfect Opposites", requested: "Oxycodone"))
        #expect(!DABMatcher.titleMatches("Something Else", requested: "Duel Links"))
    }

    @Test func titleRejectsEmptyInput() {
        #expect(!DABMatcher.titleMatches("", requested: "Oxycodone"))
        #expect(!DABMatcher.titleMatches("Oxycodone", requested: ""))
    }

    // MARK: - Artist matches

    @Test func artistExactMatch() {
        #expect(DABMatcher.artistMatches("*67", requested: "*67"))
    }

    @Test func artistCaseInsensitive() {
        #expect(DABMatcher.artistMatches("juice wrld", requested: "Juice WRLD"))
    }

    @Test func artistContainsAlias() {
        // "WTM Scoob" contains "Scoob".
        #expect(DABMatcher.artistMatches("WTM Scoob", requested: "Scoob"))
    }

    @Test func artistRejectsWrongArtist() {
        // The classic failure mode: same title, completely wrong artist.
        // Without the artist check the chain prefers DAB FLAC of a cover.
        #expect(!DABMatcher.artistMatches("Juice WRLD", requested: "WTM Scoob"))
        #expect(!DABMatcher.artistMatches("COFFEEBLACK", requested: "*67"))
    }

    @Test func artistRejectsEmptyInput() {
        #expect(!DABMatcher.artistMatches("", requested: "Artist"))
        #expect(!DABMatcher.artistMatches("Artist", requested: ""))
    }

    // MARK: - Fuzzy threshold

    @Test func jaroSimilaritySelfIsOne() {
        #expect(abs(DABMatcher.jaroSimilarity("yeat", "yeat") - 1.0) < 0.0001)
    }

    @Test func jaroSimilarityHandlesEmptyStrings() {
        #expect(abs(DABMatcher.jaroSimilarity("", "") - 1.0) < 0.0001)
        #expect(abs(DABMatcher.jaroSimilarity("", "abc") - 0.0) < 0.0001)
    }

    @Test func fuzzyAcceptsSinglyTypoedArtist() {
        // "Frnak Ocean" vs "Frank Ocean" — one transposition. Jaro should
        // score this comfortably above 0.85 and the matcher accepts.
        #expect(DABMatcher.match("Frnak Ocean", requested: "Frank Ocean"))
    }

    @Test func fuzzyRejectsDifferentArtist() {
        // "Juice WRLD" vs "Drake" — no plausible fuzzy bridge.
        #expect(!DABMatcher.match("Juice WRLD", requested: "Drake"))
    }

    // MARK: - End-to-end: matches() on a DabTrack

    @Test func dabTrackBothFieldsMustMatch() {
        // Build a synthetic DabTrack via JSON decoding — that's how the
        // production code path constructs them too.
        let json = """
        {
            "id": 12345,
            "title": "Oxycodone",
            "artist": "*67",
            "album_title": "Some Album",
            "album_id": 1,
            "duration": 180,
            "audio_quality": null
        }
        """.data(using: .utf8)!
        let track = try! JSONDecoder().decode(DabTrack.self, from: json)

        let storage = TokenStorage()
        let client = DABClient(tokenStorage: storage)

        // Both fields match → accept.
        #expect(client.matches(dabTrack: track, artist: "*67", title: "Oxycodone"))

        // Wrong artist, right title → reject (the documented bug class).
        #expect(!client.matches(dabTrack: track, artist: "Drake", title: "Oxycodone"))

        // Right artist, wrong title → reject.
        #expect(!client.matches(dabTrack: track, artist: "*67", title: "Different Song"))
    }
}
