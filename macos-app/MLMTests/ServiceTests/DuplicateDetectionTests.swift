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
}
