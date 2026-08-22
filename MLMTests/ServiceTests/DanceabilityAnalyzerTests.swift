import Testing
import Foundation
import GRDB
@testable import MLM

@MainActor
@Suite("Danceability Analyzer Tests")
struct DanceabilityAnalyzerTests {

    @Test func testScoreToLevelMapping() async throws {
        // Test lower bounds and typical values in DanceabilitySteps
        #expect(DanceabilitySteps.scoreToLevel(0.0) == 1)
        #expect(DanceabilitySteps.scoreToLevel(0.15) == 1)
        #expect(DanceabilitySteps.scoreToLevel(0.2) == 1)
        #expect(DanceabilitySteps.scoreToLevel(0.21) == 2)
        #expect(DanceabilitySteps.scoreToLevel(0.4) == 2)
        #expect(DanceabilitySteps.scoreToLevel(0.41) == 3)
        #expect(DanceabilitySteps.scoreToLevel(0.6) == 3)
        #expect(DanceabilitySteps.scoreToLevel(0.61) == 4)
        #expect(DanceabilitySteps.scoreToLevel(0.8) == 4)
        #expect(DanceabilitySteps.scoreToLevel(0.81) == 5)
        #expect(DanceabilitySteps.scoreToLevel(1.0) == 5)
    }

    @Test func testDanceabilityAnalyzerAvailability() async throws {
        let analyzer = DanceabilityAnalyzer()
        // If ffmpeg is installed, isAvailable is true.
        // The test suite runs in environment where ffmpeg is usually installed,
        // but either true or false is fine — we just verify the property executes cleanly.
        let _ = analyzer.isAvailable
    }

    @Test func testAnalyzeNonExistentFileReturnsNilOrThrows() async throws {
        let analyzer = DanceabilityAnalyzer()
        let result = try? await analyzer.analyzeTrack(path: "/nonexistent/path/song.mp3")
        #expect(result == nil)
    }

    @Test func testBatchAnalyzeEmptyTracksReturnsZero() async throws {
        let db = try DatabaseManager.inMemory()
        let trackRepo = TrackRepository(database: db)
        let analyzer = DanceabilityAnalyzer()

        let result = await analyzer.batchAnalyze(
            tracks: [],
            trackRepository: trackRepo
        )

        #expect(result.analyzed == 0)
        #expect(result.failed == 0)
        #expect(result.cancelled == false)
    }
}
