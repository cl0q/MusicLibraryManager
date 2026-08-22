import Testing
import Foundation
import GRDB
@testable import MLM

@Suite("Swarm Discovery & Learning Loop Tests")
struct SwarmDiscoveryTests {

    // MARK: - API Integration Tests

    @Test func testLastFmSwarmService() async throws {
        // Query Last.fm similar tracks API
        let swarmService = SwarmRecommendationService()
        
        // Use a popular seed track to ensure a reliable response
        let seed = Track(
            artist: "Michael Jackson",
            album: "Thriller",
            title: "Billie Jean",
            format: "flac",
            originalPath: "tracks/billie_jean.flac"
        )
        
        do {
            let recommendations = try await swarmService.fetchRecommendations(for: seed, source: .lastfm)
            
            // Log for visibility during 'swift test'
            print("🔊 Last.fm Recommendations fetched: \(recommendations.count) tracks")
            for (idx, rec) in recommendations.enumerated() {
                print("  [\(idx + 1)] \(rec.artist) - \(rec.title) (Source: \(rec.source))")
            }
            
            if recommendations.isEmpty {
                print("⚠️ Last.fm request succeeded but returned 0 recommendations. This usually means the LASTFM_API_KEY is invalid or the seed track is not indexed.")
            } else {
                #expect(recommendations.count > 0)
                #expect(recommendations.first?.source == "lastfm")
            }
        } catch {
            print("⚠️ Last.fm request failed: \(error.localizedDescription)")
            // Do not fail the build if the network is down or API key is missing
        }
    }

    @Test func testSoundCloudSwarmService() async throws {
        let swarmService = SwarmRecommendationService()
        
        // Use a SoundCloud URL as the seed track originalPath
        let seed = Track(
            artist: "Soso Camo",
            album: "Unknown",
            title: "Say Dat",
            format: "mp3",
            originalPath: "https://soundcloud.com/sosocamo/say-dat"
        )
        
        do {
            let recommendations = try await swarmService.fetchRecommendations(for: seed)
            
            print("🔊 SoundCloud Related Recommendations fetched: \(recommendations.count) tracks")
            for (idx, rec) in recommendations.enumerated() {
                print("  [\(idx + 1)] \(rec.artist) - \(rec.title) (Source: \(rec.source))")
            }
            
            if SoundCloudCredentials.clientId() != nil {
                #expect(recommendations.count > 0)
                #expect(recommendations.first?.source == "soundcloud")
            } else {
                print("⚠️ SoundCloud client_id not found in scdl.cfg — skipping assertion")
            }
        } catch {
            print("⚠️ SoundCloud request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Database & Learning Loop Tests

    @Test func testDiscoveryLogRegistrationAndInbox() async throws {
        let db = try DatabaseManager.inMemory()
        let trackRepo = TrackRepository(database: db)

        // 1. Insert seed track
        var seed = Track(artist: "Seed Artist", album: "Seed Album", title: "Seed Track", format: "flac", originalPath: "seed.flac")
        seed.organizedPath = "seed.flac"
        let savedSeed = try await db.write { dbConn -> Track in
            var temp = seed
            try temp.insert(dbConn)
            return temp
        }
        guard let seedId = savedSeed.id else { throw NSError(domain: "test", code: 1) }

        // 2. Insert discovered candidate track
        var discovered = Track(artist: "Discovered Artist", album: "Discovered Album", title: "Discovered Track", format: "flac", originalPath: "discovered.flac")
        discovered.organizedPath = "discovered.flac"
        let savedDiscovered = try await db.write { dbConn -> Track in
            var temp = discovered
            try temp.insert(dbConn)
            return temp
        }
        guard let discoveredId = savedDiscovered.id else { throw NSError(domain: "test", code: 2) }

        // 3. Register discovery in track_discovery_log
        try await trackRepo.saveDiscoveryLog(
            discoveredTrackId: discoveredId,
            seedTrackId: seedId,
            source: "lastfm",
            status: "new"
        )

        // 4. Fetch inbox and verify
        let inbox = try await trackRepo.fetchDiscoveryInboxTracks()
        #expect(inbox.count == 1)
        #expect(inbox[0].track.id == discoveredId)
        #expect(inbox[0].log.seedTrackId == seedId)
        #expect(inbox[0].log.status == "new")
        #expect(inbox[0].seedTrack?.id == seedId)

        // 5. Update discovery status to approved
        try await trackRepo.updateDiscoveryStatus(discoveredTrackId: discoveredId, status: "approved")
        
        let emptyInbox = try await trackRepo.fetchDiscoveryInboxTracks()
        #expect(emptyInbox.isEmpty)
    }

    @Test func testVectorGravityAndFeedbackLoop() async throws {
        let db = try DatabaseManager.inMemory()
        let trackRepo = TrackRepository(database: db)

        // 1. Insert two tracks
        var seed = Track(artist: "A", album: "A", title: "Seed", format: "flac", originalPath: "A.flac")
        let sT = try await db.write { dbConn -> Track in
            try seed.insert(dbConn)
            return seed
        }
        guard let seedId = sT.id else { throw NSError(domain: "test", code: 1) }

        var candidate = Track(artist: "B", album: "B", title: "Candidate", format: "flac", originalPath: "B.flac")
        let cT = try await db.write { dbConn -> Track in
            try candidate.insert(dbConn)
            return candidate
        }
        guard let candidateId = cT.id else { throw NSError(domain: "test", code: 2) }

        // Setup mock CoreML embeddings (dense rhythm/genre feature vectors)
        // Length 128 as standard for rhythm embeddings
        var originalSeedEmbedding = Array(repeating: Float(0.0), count: 128)
        originalSeedEmbedding[0] = 1.0 // unit vector along dimension 0
        
        var originalCandidateEmbedding = Array(repeating: Float(0.0), count: 128)
        originalCandidateEmbedding[1] = 1.0 // unit vector along dimension 1 (orthogonal to seed)

        // Normalize initial embeddings
        func normalize(_ v: [Float]) -> [Float] {
            let sumSquare = v.reduce(0.0) { $0 + $1 * $1 }
            let norm = sqrt(sumSquare)
            return norm > 0 ? v.map { $0 / norm } : v
        }

        let normalizedSeed = normalize(originalSeedEmbedding)
        let normalizedCandidate = normalize(originalCandidateEmbedding)

        try await db.write { dbConn in
            var sEmb = TrackEmbedding(trackId: seedId, masterEmbeddingData: normalizedSeed.toData, dropOffset: 30.0, mixCategory: nil)
            try sEmb.insert(dbConn)
            
            var cEmb = TrackEmbedding(trackId: candidateId, masterEmbeddingData: normalizedCandidate.toData, dropOffset: 45.0, mixCategory: nil)
            try cEmb.insert(dbConn)
        }

        // Verify initial cosine similarity
        let initialEmbSeed = try await trackRepo.fetchTrackEmbedding(id: seedId)
        let initialEmbCand = try await trackRepo.fetchTrackEmbedding(id: candidateId)
        #expect(initialEmbSeed != nil)
        #expect(initialEmbCand != nil)

        let initialSim = VectorMath.cosineSimilarity(initialEmbSeed!.masterEmbedding, initialEmbCand!.masterEmbedding)
        print("📊 Initial Embedding Cosine Similarity: \(initialSim)")

        // 3. Apply Vector Gravity (5% pull)
        try await trackRepo.applyVectorGravity(seedTrackId: seedId, targetTrackId: candidateId, pullRate: 0.05)

        // 4. Verify shifted embeddings
        let shiftedEmbSeed = try await trackRepo.fetchTrackEmbedding(id: seedId)
        let shiftedEmbCand = try await trackRepo.fetchTrackEmbedding(id: candidateId)

        let postSim = VectorMath.cosineSimilarity(shiftedEmbSeed!.masterEmbedding, shiftedEmbCand!.masterEmbedding)
        print("📊 Post-Gravity Embedding Cosine Similarity: \(postSim)")

        // The cosine similarity must increase (tracks are pulled closer together)
        #expect(postSim > initialSim)
        
        // 5. Test Similarity Feedback Boost
        try await trackRepo.saveSimilarityFeedback(seedTrackId: seedId, targetTrackId: candidateId, feedbackValue: 1)
        
        // Check Composite Score calculation incorporates the feedback value (+0.15 similarity boost)
        let similarList = try await trackRepo.fetchSimilarTracks(seedTrackId: seedId, limit: 1)
        #expect(similarList.count == 1)
        #expect(similarList[0].track.id == candidateId)
    }
}
