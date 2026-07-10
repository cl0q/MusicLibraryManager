import Foundation
import GRDB

// MARK: - Float Array Binary Serialization Extension

extension Array where Element == Float {
    /// Convert a Float array directly to Data bytes (very fast, zero overhead)
    var toData: Data {
        return self.withUnsafeBytes { Data($0) }
    }
    
    /// Reconstruct a Float array from Data bytes
    static func fromData(_ data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }
    }
}

// MARK: - TrackEmbedding Model

/// Holds the main/master CoreML audio embedding for a track.
/// Maps directly to the `track_embeddings` table in SQLite.
struct TrackEmbedding: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    var id: Int64 { trackId } // Identifiable convenience mapping to trackId
    var trackId: Int64
    var masterEmbeddingData: Data
    var dropOffset: Double
    var mixCategory: String? // "Chill House", "Vixa Club" or nil for standard tracks

    // Convenience computed property to access the floating-point vector
    var masterEmbedding: [Float] {
        get { [Float].fromData(masterEmbeddingData) }
        set { masterEmbeddingData = newValue.toData }
    }

    static let databaseTableName = "track_embeddings"

    enum Columns {
        static let trackId = Column(CodingKeys.trackId)
        static let masterEmbeddingData = Column("master_embedding")
        static let dropOffset = Column(CodingKeys.dropOffset)
        static let mixCategory = Column(CodingKeys.mixCategory)
    }

    enum CodingKeys: String, CodingKey {
        case trackId = "track_id"
        case masterEmbeddingData = "master_embedding"
        case dropOffset = "drop_offset"
        case mixCategory = "mix_category"
    }
}

// MARK: - TrackSegmentEmbedding Model

/// Holds segment-level embeddings of a track for micro-matching and seeking.
/// Maps directly to the `track_segment_embeddings` table in SQLite.
struct TrackSegmentEmbedding: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    var id: Int64?
    var trackId: Int64
    var offsetSeconds: Double
    var segmentEmbeddingData: Data

    // Convenience computed property to access the floating-point vector
    var segmentEmbedding: [Float] {
        get { [Float].fromData(segmentEmbeddingData) }
        set { segmentEmbeddingData = newValue.toData }
    }

    static let databaseTableName = "track_segment_embeddings"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let trackId = Column(CodingKeys.trackId)
        static let offsetSeconds = Column(CodingKeys.offsetSeconds)
        static let segmentEmbeddingData = Column("segment_embedding")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case trackId = "track_id"
        case offsetSeconds = "offset_seconds"
        case segmentEmbeddingData = "segment_embedding"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - TrackSimilarityFeedback Model

/// Holds thumbs up/down user feedback for song recommendations to build a learning system.
/// Maps directly to the `track_similarity_feedback` table in SQLite.
struct TrackSimilarityFeedback: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    var seedTrackId: Int64
    var targetTrackId: Int64
    var feedbackValue: Int // +1 (good match), -1 (bad match)
    var dateCreated: Date = Date()

    static let databaseTableName = "track_similarity_feedback"

    enum Columns {
        static let seedTrackId = Column(CodingKeys.seedTrackId)
        static let targetTrackId = Column(CodingKeys.targetTrackId)
        static let feedbackValue = Column(CodingKeys.feedbackValue)
        static let dateCreated = Column(CodingKeys.dateCreated)
    }

    enum CodingKeys: String, CodingKey {
        case seedTrackId = "seed_track_id"
        case targetTrackId = "target_track_id"
        case feedbackValue = "feedback_value"
        case dateCreated = "date_created"
    }
}

// MARK: - Mix Categories & Classifier

enum MixCategory: String, Codable {
    case chillHouse = "Chill House"
    case vixaClub = "Vixa Club"
    case unknown = "Unknown"
}

struct MixClassifier {
    static func classify(
        bpm: Double,
        avgLufs: Double,
        lufsRange: Double,
        artist: String,
        title: String
    ) -> MixCategory {
        let artistLower = artist.lowercased()
        let titleLower = title.lowercased()
        
        // Rule 1: Specific artist/title matching (User's specific request)
        if artistLower.contains("gesus8") || titleLower.contains("deep house") || titleLower.contains("deep house therapy") {
            return .chillHouse
        }
        if artistLower.contains("hazel") || artistLower.contains("ekwador") || 
           artistLower.contains("cabay") || artistLower.contains("endriu") || 
           artistLower.contains("damien") || titleLower.contains("ekwador") || 
           titleLower.contains("vixa") || titleLower.contains("club mix") {
            return .vixaClub
        }
        
        // Rule 2: Acoustic heuristics
        if bpm > 132.0 && avgLufs > -9.0 {
            return .vixaClub
        } else if bpm < 125.0 && avgLufs < -10.0 {
            return .chillHouse
        }
        
        return .unknown
    }
}

// MARK: - TrackDiscoveryLog Model

/// Holds the logs and context of tracks discovered via the remote swarm intelligence.
/// Maps directly to the `track_discovery_log` table in SQLite.
struct TrackDiscoveryLog: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    var discoveredTrackId: Int64
    var seedTrackId: Int64?
    var discoverySource: String // 'spotify', 'lastfm', 'soundcloud'
    var status: String = "new" // 'new', 'approved', 'rejected'
    var dateAdded: Date = Date()

    static let databaseTableName = "track_discovery_log"

    enum Columns {
        static let discoveredTrackId = Column(CodingKeys.discoveredTrackId)
        static let seedTrackId = Column(CodingKeys.seedTrackId)
        static let discoverySource = Column(CodingKeys.discoverySource)
        static let status = Column(CodingKeys.status)
        static let dateAdded = Column(CodingKeys.dateAdded)
    }

    enum CodingKeys: String, CodingKey {
        case discoveredTrackId = "discovered_track_id"
        case seedTrackId = "seed_track_id"
        case discoverySource = "discovery_source"
        case status = "status"
        case dateAdded = "date_added"
    }
}
