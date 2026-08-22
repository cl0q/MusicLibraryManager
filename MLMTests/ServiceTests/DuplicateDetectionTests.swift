import Testing
import Foundation
@testable import MLM

@Suite("Duplicate Detection & Jaro-Winkler Tests")
struct DuplicateDetectionTests {

    @Test func jaroWinklerExactMatch() {
        #expect(DuplicateMatcher.jaroWinkler("hello", "hello") == 1.0)
    }

    @Test func jaroWinklerEmptyStrings() {
        #expect(DuplicateMatcher.jaroWinkler("", "hello") == 0.0)
        #expect(DuplicateMatcher.jaroWinkler("hello", "") == 0.0)
        #expect(DuplicateMatcher.jaroWinkler("", "") == 1.0)
    }

    @Test func jaroWinklerHighlyDifferentLengthsDoesNotCrash() {
        // This is the classic crash case where max(len1, len2) / 2 - 1 is large
        // but one string is very short. Let's verify it returns a valid score
        // instead of throwing range or bounds violations!
        let longString = String(repeating: "A", count: 100)
        let shortString = "AA"
        
        let score1 = DuplicateMatcher.jaroWinkler(longString, shortString)
        let score2 = DuplicateMatcher.jaroWinkler(shortString, longString)
        
        #expect(score1 >= 0.0 && score1 <= 1.0)
        #expect(score2 >= 0.0 && score2 <= 1.0)
    }

    @Test func jaroWinklerTypicalSimilarStrings() {
        let score = DuplicateMatcher.jaroWinkler("MARTHA", "MARHTA")
        #expect(score > 0.9 && score < 1.0)
    }

    @Test func variantClassifierRecognizesVersionedRecording() {
        #expect(DuplicateMatcher.isVariant(
            title1: "Song (Radio Edit)", artist1: "Artist",
            title2: "Song", artist2: "Artist"
        ))
    }

    @Test func groupingUsesTransitiveUnionAndStableKeys() {
        let groups = DuplicateReviewGrouping.groups(matches: [
            DuplicateReviewMatch(trackAId: 3, trackBId: 2),
            DuplicateReviewMatch(trackAId: 1, trackBId: 2),
            DuplicateReviewMatch(trackAId: 11, trackBId: 10),
        ])

        #expect(groups.map(\.memberTrackIds) == [[1, 2, 3], [10, 11]])
        #expect(groups.map(\.key) == ["duplicate:1:2:3", "duplicate:10:11"])
    }

    @Test func recommendationIsDeterministicAndPrioritizesLosslessQuality() {
        var lowerIDLossy = Track(
            artist: "Artist", album: "Album", title: "Song", format: "mp3", originalPath: "/1.mp3"
        )
        lowerIDLossy.id = 1
        lowerIDLossy.bitrate = 320

        var lossless = Track(
            artist: "Artist", album: "Album", title: "Song", format: "flac", originalPath: "/2.flac"
        )
        lossless.id = 2
        lossless.bitrate = 900

        let recommendation = DuplicateReviewRecommendation.recommendation(
            for: [lowerIDLossy, lossless],
            keepBoth: false
        )

        #expect(recommendation?.action == .keepTrack)
        #expect(recommendation?.trackId == 2)
        #expect(recommendation?.reasons.contains("lossless format") == true)
    }

    @Test func reviewDetailsDecodesLegacyPairPayload() throws {
        let legacy = """
        {
          "similarity_score": 0.96,
          "track_a": {"id": 1, "title": "Song", "artist": "Artist"},
          "track_b": {"id": 2, "title": "Song", "artist": "Artist"}
        }
        """

        let details = try ReviewDetails.decodeJSON(legacy)

        #expect(details.similarityScore == 0.96)
        #expect(details.evidence?.fingerprintSimilarity == 0.96)
        #expect(details.trackA?.id == 1)
        #expect(details.trackB?.id == 2)
        #expect(try ReviewDetails.decodeJSON(details.encodedJSON()).trackA?.title == "Song")
    }
}
