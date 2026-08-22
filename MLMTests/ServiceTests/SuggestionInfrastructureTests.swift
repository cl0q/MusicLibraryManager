import Testing
import Foundation
@testable import MLM

@Suite("Suggestion Infrastructure Tests")
struct SuggestionInfrastructureTests {

    // MARK: - Vector Math Tests

    @Test func testCosineSimilarityIdentical() throws {
        let v1: [Float] = [1.0, 2.0, 3.0]
        let v2: [Float] = [1.0, 2.0, 3.0]
        let sim = VectorMath.cosineSimilarity(v1, v2)
        #expect(abs(sim - 1.0) < 1e-5)
    }

    @Test func testCosineSimilarityOrthogonal() throws {
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [0.0, 1.0, 0.0]
        let sim = VectorMath.cosineSimilarity(v1, v2)
        #expect(abs(sim - 0.0) < 1e-5)
    }

    @Test func testCosineSimilarityOpposite() throws {
        let v1: [Float] = [1.0, 2.0, 3.0]
        let v2: [Float] = [-1.0, -2.0, -3.0]
        let sim = VectorMath.cosineSimilarity(v1, v2)
        #expect(abs(sim - (-1.0)) < 1e-5)
    }

    @Test func testCosineSimilarityMismatchedLength() throws {
        let v1: [Float] = [1.0, 2.0]
        let v2: [Float] = [1.0, 2.0, 3.0]
        let sim = VectorMath.cosineSimilarity(v1, v2)
        #expect(sim == 0.0)
    }

    @Test func testCosineSimilarityEmpty() throws {
        let v1: [Float] = []
        let v2: [Float] = []
        let sim = VectorMath.cosineSimilarity(v1, v2)
        #expect(sim == 0.0)
    }

    @Test func testEuclideanDistanceIdentical() throws {
        let v1: [Float] = [1.0, 2.0, 3.0]
        let v2: [Float] = [1.0, 2.0, 3.0]
        let dist = VectorMath.euclideanDistance(v1, v2)
        #expect(dist == 0.0)
    }

    @Test func testEuclideanDistanceCalculation() throws {
        let v1: [Float] = [1.0, 0.0]
        let v2: [Float] = [4.0, 4.0] // diff is [-3.0, -4.0], sum of squares is 9+16=25, sqrt is 5.0
        let dist = VectorMath.euclideanDistance(v1, v2)
        #expect(abs(dist - 5.0) < 1e-5)
    }

    // MARK: - Audio Preprocessor Segmentation Tests

    @Test func testSegmentationNormal() throws {
        let samples: [Float] = Array(repeating: 1.0, count: 32000)
        let segmented = AudioPreprocessor.segment(samples: samples, windowSize: 10000)
        
        #expect(segmented.count == 3)
        #expect(segmented[0].count == 10000)
        #expect(segmented[1].count == 10000)
        #expect(segmented[2].count == 10000)
    }

    @Test func testSegmentationTooShort() throws {
        let samples: [Float] = [1.0, 2.0, 3.0]
        let segmented = AudioPreprocessor.segment(samples: samples, windowSize: 10)
        #expect(segmented.isEmpty)
    }

    // MARK: - Database Suggestion & Ranking Tests

    @Test func testDatabaseSimilarityAndRanking() async throws {
        let db = try DatabaseManager.inMemory()
        let trackRepo = TrackRepository(database: db)

        // Insert mock tracks in a safe, Swift 6 compliant concurrency-friendly way
        var t1 = Track(artist: "Crusy", album: "Supersonic", title: "Supersonic", format: "flac", originalPath: "track1.flac")
        t1.organizedPath = "track1.flac"
        let savedT1 = try await db.write { dbConn -> Track in
            var temp = t1
            try temp.insert(dbConn)
            return temp
        }

        var t2 = Track(artist: "Crusy", album: "Selecta", title: "Selecta", format: "flac", originalPath: "track2.flac")
        t2.organizedPath = "track2.flac"
        let savedT2 = try await db.write { dbConn -> Track in
            var temp = t2
            try temp.insert(dbConn)
            return temp
        }

        var t3 = Track(artist: "DJ Hazel", album: "Poland", title: "I Love Poland", format: "mp3", originalPath: "track3.mp3")
        t3.organizedPath = "track3.mp3"
        let savedT3 = try await db.write { dbConn -> Track in
            var temp = t3
            try temp.insert(dbConn)
            return temp
        }

        let id1 = savedT1.id!
        let id2 = savedT2.id!
        let id3 = savedT3.id!

        // Save embeddings (YAMNet mock embeddings of size 1024)
        var e1 = [Float](repeating: 0.0, count: 1024)
        e1[0] = 1.0
        try await trackRepo.saveTrackEmbedding(trackId: id1, embedding: e1, dropOffset: 45.0, mixCategory: nil)

        var e2 = [Float](repeating: 0.0, count: 1024)
        e2[0] = 0.9
        e2[1] = 0.1
        try await trackRepo.saveTrackEmbedding(trackId: id2, embedding: e2, dropOffset: 50.0, mixCategory: nil)

        var e3 = [Float](repeating: 0.0, count: 1024)
        e3[500] = 1.0
        try await trackRepo.saveTrackEmbedding(trackId: id3, embedding: e3, dropOffset: 30.0, mixCategory: nil)

        // Save detailed segments for t2
        try await trackRepo.saveTrackSegmentEmbeddings(trackId: id2, segments: [
            (offset: 10.0, embedding: [Float](repeating: 0.0, count: 1024)),
            (offset: 50.0, embedding: e2) // drop segment
        ])

        // 1. Fetch similar tracks for Crusy - Supersonic (id1)
        var results = try await trackRepo.fetchSimilarTracks(seedTrackId: id1, limit: 10)
        #expect(results.count == 2)
        
        // Assert sorting: Crusy - Selecta (id2) must be first (score should be higher)
        #expect(results[0].track.id == id2)
        #expect(results[0].score > 0.8)
        #expect(results[0].bestMatchOffset == 50.0) // should dynamically match the correct offset!

        #expect(results[1].track.id == id3)
        #expect(results[1].score < 0.1)

        // 2. Test user feedback: Negative feedback on DJ Hazel should hide it
        try await trackRepo.saveSimilarityFeedback(seedTrackId: id1, targetTrackId: id3, feedbackValue: -1)
        results = try await trackRepo.fetchSimilarTracks(seedTrackId: id1, limit: 10)
        #expect(results.count == 1)
        #expect(results[0].track.id == id2)

        // 3. Test mix types: Mix categories should not mix with standard tracks
        var mix1 = Track(artist: "Gesus8", album: "House Mix", title: "Sunny House", format: "m4a", originalPath: "mix1.m4a")
        mix1.organizedPath = "mix1.m4a"
        let _ = try await db.write { dbConn -> Track in
            var temp = mix1
            try temp.insert(dbConn)
            return temp
        }
        
        let mixId = mix1.id ?? 4 // fallback if not set on t1, but let's check t1 id which is 4
        try await trackRepo.saveTrackEmbedding(trackId: mixId, embedding: e1, dropOffset: 120.0, mixCategory: "Chill House")

        // Standard track similarity query should NOT return mix1
        results = try await trackRepo.fetchSimilarTracks(seedTrackId: id1, limit: 10)
        #expect(results.contains(where: { $0.track.id == mixId }) == false)
    }

    @Test func testAudioEmbeddingServiceAvailability() async throws {
        let service = AudioEmbeddingService()
        let prep = AudioPreprocessor()
        print("--- DIAGNOSTIC INFO ---")
        print("service.isAvailable: \(service.isAvailable)")
        print("preprocessor.isAvailable: \(prep.isAvailable)")
        print("ffmpegPath: \(String(describing: ProcessRunner.findExecutable("ffmpeg")))")
        print("-----------------------")
    }

    @Test func testPreprocessorWithRealFiles() async throws {
        let prep = AudioPreprocessor()
        #expect(prep.isAvailable)
        
        let path = "/Volumes/Lexxar/Music/00_Artist/Yeat/Yeat/Alivë [U]/Autumn! - Probably [V2].mp3"
        if FileManager.default.fileExists(atPath: path) {
            do {
                let samples = try await prep.resampleTo16kHzMono(at: path, startOffset: 24.0, duration: 120.0)
                #expect(samples != nil)
                #expect(samples!.count > 0)
                print("Native preprocessor extracted \(samples!.count) samples successfully!")
            } catch {
                Issue.record("Failed to resample natively: \(error)")
            }
        } else {
            print("Test skipped because file is not present: \(path)")
        }
    }
}
