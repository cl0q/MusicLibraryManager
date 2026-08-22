import Foundation

/// Persisted evidence for one fingerprint-matched pair within a review group.
struct ReviewPairEvidence: Codable, Equatable, Sendable {
    var trackAId: Int64
    var trackBId: Int64
    var fingerprintSimilarity: Double
    var titleSimilarity: Double
    var artistSimilarity: Double
    var conflictingFields: [String]
    var isVariant: Bool

    enum CodingKeys: String, CodingKey {
        case trackAId = "track_a_id"
        case trackBId = "track_b_id"
        case fingerprintSimilarity = "fingerprint_similarity"
        case titleSimilarity = "title_similarity"
        case artistSimilarity = "artist_similarity"
        case conflictingFields = "conflicting_fields"
        case isVariant = "is_variant"
    }
}

/// Aggregate evidence shown for a review group.
struct ReviewEvidence: Codable, Equatable, Sendable {
    var fingerprintSimilarity: Double?
    var pairs: [ReviewPairEvidence]

    init(fingerprintSimilarity: Double? = nil, pairs: [ReviewPairEvidence] = []) {
        self.fingerprintSimilarity = fingerprintSimilarity
        self.pairs = pairs
    }

    enum CodingKeys: String, CodingKey {
        case fingerprintSimilarity = "fingerprint_similarity"
        case pairs
    }
}

/// Similarity scores for fields that can disagree between versions.
struct ReviewFieldScores: Codable, Equatable, Sendable {
    var titleSimilarity: Double?
    var artistSimilarity: Double?
    /// Per-field scores retained for the metadata-conflict diff. Optional
    /// keeps details JSON produced before field-level review readable.
    var scores: [String: Double]?

    init(
        titleSimilarity: Double? = nil,
        artistSimilarity: Double? = nil,
        scores: [String: Double]? = nil
    ) {
        self.titleSimilarity = titleSimilarity
        self.artistSimilarity = artistSimilarity
        self.scores = scores
    }

    enum CodingKeys: String, CodingKey {
        case titleSimilarity = "title_similarity"
        case artistSimilarity = "artist_similarity"
        case scores
    }
}

/// Describes a same-recording but distinct-version classification.
struct ReviewVariant: Codable, Equatable, Sendable {
    var isVariant: Bool
    var explanation: String?

    init(isVariant: Bool, explanation: String? = nil) {
        self.isVariant = isVariant
        self.explanation = explanation
    }

    enum CodingKeys: String, CodingKey {
        case isVariant = "is_variant"
        case explanation
    }
}

enum ReviewRecommendationAction: String, Codable, Sendable {
    case keepTrack = "keep_track"
    case keepBoth = "keep_both"
}

/// A deterministic scan recommendation. Applying it remains a later user action.
struct ReviewRecommendation: Codable, Equatable, Sendable {
    var action: ReviewRecommendationAction
    var trackId: Int64?
    var reasons: [String]

    init(action: ReviewRecommendationAction, trackId: Int64? = nil, reasons: [String] = []) {
        self.action = action
        self.trackId = trackId
        self.reasons = reasons
    }

    enum CodingKeys: String, CodingKey {
        case action
        case trackId = "track_id"
        case reasons
    }
}

/// A durable record of a future user resolution, retained so it can be undone.
struct ReviewResolutionSnapshot: Codable, Equatable, Sendable {
    var action: String
    var keptTrackIds: [Int64]
    var unkeptTrackIds: [Int64]
    var resolvedAt: String?
    /// The marker state before the resolution. This lets an undo restore
    /// existing relationships rather than blindly clearing every marker.
    var duplicateStates: [ReviewDuplicateState]?
    /// Metadata before a field-level conflict merge. Optional keeps snapshots
    /// written by earlier app versions decodable.
    var metadataStates: [ReviewTrackMetadataSnapshot]?

    init(
        action: String,
        keptTrackIds: [Int64],
        unkeptTrackIds: [Int64],
        resolvedAt: String? = nil,
        duplicateStates: [ReviewDuplicateState]? = nil,
        metadataStates: [ReviewTrackMetadataSnapshot]? = nil
    ) {
        self.action = action
        self.keptTrackIds = keptTrackIds
        self.unkeptTrackIds = unkeptTrackIds
        self.resolvedAt = resolvedAt
        self.duplicateStates = duplicateStates
        self.metadataStates = metadataStates
    }

    enum CodingKeys: String, CodingKey {
        case action
        case keptTrackIds = "kept_track_ids"
        case unkeptTrackIds = "unkept_track_ids"
        case resolvedAt = "resolved_at"
        case duplicateStates = "duplicate_states"
        case metadataStates = "metadata_states"
    }
}

/// The persisted duplicate relationship for one track before a resolution.
struct ReviewDuplicateState: Codable, Equatable, Sendable {
    var trackId: Int64
    var isDuplicate: Int
    var variantOf: Int64?

    enum CodingKeys: String, CodingKey {
        case trackId = "track_id"
        case isDuplicate = "is_duplicate"
        case variantOf = "variant_of"
    }
}

/// Metadata that can be changed by a field-level review merge.
struct ReviewTrackMetadataSnapshot: Codable, Equatable, Sendable {
    var trackId: Int64
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var genre: String?
    var year: Int?

    init(track: Track) {
        trackId = track.id ?? 0
        title = track.title
        artist = track.artist
        albumArtist = track.albumArtist
        album = track.album
        genre = track.genre
        year = track.year
    }

    enum CodingKeys: String, CodingKey {
        case trackId = "track_id"
        case title, artist, album, genre, year
        case albumArtist = "album_artist"
    }
}

enum ReviewResolutionAction: String, Codable, Sendable {
    case keepRecommended = "keep_recommended"
    case keepManual = "keep_manual"
    case keepAll = "keep_all"
    case mergeMetadata = "merge_metadata"
    case dismiss = "dismiss"
}

enum ReviewMetadataField: String, CaseIterable, Codable, Hashable, Sendable {
    case title
    case artist
    case albumArtist = "album_artist"
    case album
    case genre
    case year

    var label: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .albumArtist: "Album artist"
        case .album: "Album"
        case .genre: "Genre"
        case .year: "Year"
        }
    }
}

/// Values selected in the metadata-conflict UI. The selected fields are
/// explicit so choosing an empty genre can still be applied deliberately.
struct ReviewMetadataMerge: Equatable, Sendable {
    var fields: Set<ReviewMetadataField>
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var genre: String?
    var year: Int?

    init(fields: Set<ReviewMetadataField>, source: Track) {
        self.fields = fields
        title = source.title
        artist = source.artist
        albumArtist = source.albumArtist
        album = source.album
        genre = source.genre
        year = source.year
    }
}

/// Stable track data retained with a review so its evidence remains intelligible.
struct ReviewTrackSnapshot: Codable, Equatable, Sendable {
    var id: Int64
    var title: String
    var artist: String
    var albumArtist: String?
    var album: String?
    var genre: String?
    var year: Int?
    var format: String?
    var bitrate: Int?
    var duration: Int?
    var organizedPath: String?

    init(
        id: Int64,
        title: String,
        artist: String,
        albumArtist: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        format: String? = nil,
        bitrate: Int? = nil,
        duration: Int? = nil,
        organizedPath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.genre = genre
        self.year = year
        self.format = format
        self.bitrate = bitrate
        self.duration = duration
        self.organizedPath = organizedPath
    }

    init(track: Track) {
        self.init(
            id: track.id ?? 0,
            title: track.title,
            artist: track.artist,
            albumArtist: track.albumArtist,
            album: track.album,
            genre: track.genre,
            year: track.year,
            format: track.format,
            bitrate: track.bitrate,
            duration: track.duration,
            organizedPath: track.organizedPath
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, genre, year, format, bitrate, duration
        case albumArtist = "album_artist"
        case organizedPath = "organized_path"
    }
}

/// Versioned review payload stored as JSON in `review_queue.details`.
///
/// It also decodes and re-encodes the original pair payload (`similarity_score`,
/// `track_a`, and `track_b`) so existing queue rows stay readable.
struct ReviewDetails: Codable, Equatable, Sendable {
    var groupKey: String?
    var evidence: ReviewEvidence?
    var fieldScores: ReviewFieldScores?
    var conflictingFields: [String]
    var variant: ReviewVariant?
    var recommendation: ReviewRecommendation?
    var resolutionSnapshot: ReviewResolutionSnapshot?
    var tracks: [ReviewTrackSnapshot]

    // Legacy pair fields are preserved for rows created before review groups.
    var similarityScore: Double?
    var trackA: ReviewTrackSnapshot?
    var trackB: ReviewTrackSnapshot?

    init(
        groupKey: String? = nil,
        evidence: ReviewEvidence? = nil,
        fieldScores: ReviewFieldScores? = nil,
        conflictingFields: [String] = [],
        variant: ReviewVariant? = nil,
        recommendation: ReviewRecommendation? = nil,
        resolutionSnapshot: ReviewResolutionSnapshot? = nil,
        tracks: [ReviewTrackSnapshot] = [],
        similarityScore: Double? = nil,
        trackA: ReviewTrackSnapshot? = nil,
        trackB: ReviewTrackSnapshot? = nil
    ) {
        self.groupKey = groupKey
        self.evidence = evidence
        self.fieldScores = fieldScores
        self.conflictingFields = conflictingFields
        self.variant = variant
        self.recommendation = recommendation
        self.resolutionSnapshot = resolutionSnapshot
        self.tracks = tracks
        self.similarityScore = similarityScore
        self.trackA = trackA
        self.trackB = trackB
    }

    enum CodingKeys: String, CodingKey {
        case groupKey = "group_key"
        case evidence
        case fieldScores = "field_scores"
        case conflictingFields = "conflicting_fields"
        case variant
        case recommendation
        case resolutionSnapshot = "resolution_snapshot"
        case tracks
        case similarityScore = "similarity_score"
        case trackA = "track_a"
        case trackB = "track_b"
        case titleSimilarity = "title_similarity"
        case artistSimilarity = "artist_similarity"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groupKey = try container.decodeIfPresent(String.self, forKey: .groupKey)
        evidence = try container.decodeIfPresent(ReviewEvidence.self, forKey: .evidence)
        conflictingFields = try container.decodeIfPresent([String].self, forKey: .conflictingFields) ?? []
        variant = try container.decodeIfPresent(ReviewVariant.self, forKey: .variant)
        recommendation = try container.decodeIfPresent(ReviewRecommendation.self, forKey: .recommendation)
        resolutionSnapshot = try container.decodeIfPresent(ReviewResolutionSnapshot.self, forKey: .resolutionSnapshot)
        tracks = try container.decodeIfPresent([ReviewTrackSnapshot].self, forKey: .tracks) ?? []
        similarityScore = try container.decodeIfPresent(Double.self, forKey: .similarityScore)
        trackA = try container.decodeIfPresent(ReviewTrackSnapshot.self, forKey: .trackA)
        trackB = try container.decodeIfPresent(ReviewTrackSnapshot.self, forKey: .trackB)

        fieldScores = try container.decodeIfPresent(ReviewFieldScores.self, forKey: .fieldScores)
        if fieldScores == nil {
            let titleSimilarity = try container.decodeIfPresent(Double.self, forKey: .titleSimilarity)
            let artistSimilarity = try container.decodeIfPresent(Double.self, forKey: .artistSimilarity)
            if titleSimilarity != nil || artistSimilarity != nil {
                fieldScores = ReviewFieldScores(
                    titleSimilarity: titleSimilarity,
                    artistSimilarity: artistSimilarity
                )
            }
        }

        if evidence == nil, let similarityScore {
            evidence = ReviewEvidence(fingerprintSimilarity: similarityScore)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(groupKey, forKey: .groupKey)
        try container.encodeIfPresent(evidence, forKey: .evidence)
        try container.encodeIfPresent(fieldScores, forKey: .fieldScores)
        try container.encode(conflictingFields, forKey: .conflictingFields)
        try container.encodeIfPresent(variant, forKey: .variant)
        try container.encodeIfPresent(recommendation, forKey: .recommendation)
        try container.encodeIfPresent(resolutionSnapshot, forKey: .resolutionSnapshot)
        try container.encode(tracks, forKey: .tracks)

        // Keep the original pair representation available to legacy readers.
        try container.encodeIfPresent(similarityScore ?? evidence?.fingerprintSimilarity, forKey: .similarityScore)
        try container.encodeIfPresent(trackA, forKey: .trackA)
        try container.encodeIfPresent(trackB, forKey: .trackB)
    }

    static func decodeJSON(_ json: String) throws -> ReviewDetails {
        try JSONDecoder().decode(ReviewDetails.self, from: Data(json.utf8))
    }

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// A fingerprint match used to form connected review groups.
struct DuplicateReviewMatch: Equatable, Sendable {
    var trackAId: Int64
    var trackBId: Int64

    init(trackAId: Int64, trackBId: Int64) {
        self.trackAId = min(trackAId, trackBId)
        self.trackBId = max(trackAId, trackBId)
    }
}

/// A deterministic connected component of tracks proposed for review.
struct DuplicateReviewGroup: Equatable, Sendable {
    var memberTrackIds: [Int64]

    init(memberTrackIds: [Int64]) {
        self.memberTrackIds = Array(Set(memberTrackIds)).sorted()
    }

    var key: String {
        DuplicateReviewGrouping.groupKey(for: memberTrackIds)
    }
}

/// Pure union-find grouping for transitive duplicate matches.
enum DuplicateReviewGrouping {
    static func groups(matches: [DuplicateReviewMatch]) -> [DuplicateReviewGroup] {
        let trackIds = matches.flatMap { [$0.trackAId, $0.trackBId] }
        return groups(trackIds: trackIds, matches: matches)
    }

    static func groups(
        trackIds: [Int64],
        matches: [DuplicateReviewMatch]
    ) -> [DuplicateReviewGroup] {
        var unionFind = UnionFind(trackIds)
        for match in matches.sorted(by: matchOrder) {
            unionFind.union(match.trackAId, match.trackBId)
        }

        var components: [Int64: [Int64]] = [:]
        for trackId in Set(trackIds) {
            components[unionFind.find(trackId), default: []].append(trackId)
        }

        return components.values
            .map(DuplicateReviewGroup.init(memberTrackIds:))
            .filter { $0.memberTrackIds.count > 1 }
            .sorted {
                $0.memberTrackIds.lexicographicallyPrecedes($1.memberTrackIds, by: <)
            }
    }

    static func groupKey(for trackIds: [Int64]) -> String {
        "duplicate:" + Array(Set(trackIds)).sorted().map(String.init).joined(separator: ":")
    }

    private static func matchOrder(_ lhs: DuplicateReviewMatch, _ rhs: DuplicateReviewMatch) -> Bool {
        if lhs.trackAId != rhs.trackAId { return lhs.trackAId < rhs.trackAId }
        return lhs.trackBId < rhs.trackBId
    }

    private struct UnionFind {
        private var parents: [Int64: Int64]

        init(_ values: [Int64]) {
            parents = Dictionary(uniqueKeysWithValues: Set(values).map { ($0, $0) })
        }

        mutating func find(_ value: Int64) -> Int64 {
            guard let parent = parents[value] else {
                parents[value] = value
                return value
            }
            guard parent != value else { return value }
            let root = find(parent)
            parents[value] = root
            return root
        }

        mutating func union(_ lhs: Int64, _ rhs: Int64) {
            let lhsRoot = find(lhs)
            let rhsRoot = find(rhs)
            guard lhsRoot != rhsRoot else { return }
            parents[max(lhsRoot, rhsRoot)] = min(lhsRoot, rhsRoot)
        }
    }
}

/// Stable quality ranking used only to make duplicate-review recommendations.
enum DuplicateReviewRecommendation {
    static func recommendedTrack(in tracks: [Track]) -> Track? {
        tracks.sorted(by: isPreferred).first
    }

    static func recommendation(for tracks: [Track], keepBoth: Bool) -> ReviewRecommendation? {
        if keepBoth {
            return ReviewRecommendation(
                action: .keepBoth,
                reasons: ["Same recording, different version"]
            )
        }
        guard let recommended = recommendedTrack(in: tracks), let trackId = recommended.id else {
            return nil
        }
        return ReviewRecommendation(
            action: .keepTrack,
            trackId: trackId,
            reasons: reasons(for: recommended, among: tracks)
        )
    }

    private static func isPreferred(_ lhs: Track, _ rhs: Track) -> Bool {
        let lhsLossless = isLossless(lhs)
        let rhsLossless = isLossless(rhs)
        if lhsLossless != rhsLossless { return lhsLossless }

        let lhsBitrate = lhs.bitrate ?? 0
        let rhsBitrate = rhs.bitrate ?? 0
        if lhsBitrate != rhsBitrate { return lhsBitrate > rhsBitrate }

        let lhsCompleteness = metadataCompleteness(lhs)
        let rhsCompleteness = metadataCompleteness(rhs)
        if lhsCompleteness != rhsCompleteness { return lhsCompleteness > rhsCompleteness }

        let lhsLocal = lhs.organizedPath?.isEmpty == false
        let rhsLocal = rhs.organizedPath?.isEmpty == false
        if lhsLocal != rhsLocal { return lhsLocal }

        return (lhs.id ?? Int64.max) < (rhs.id ?? Int64.max)
    }

    private static func reasons(for track: Track, among tracks: [Track]) -> [String] {
        var reasons: [String] = []
        if isLossless(track), tracks.contains(where: { !isLossless($0) }) {
            reasons.append("lossless format")
        }
        let comparableBitrates = tracks
            .filter { ($0.id ?? Int64.min) != (track.id ?? Int64.min) && isLossless($0) == isLossless(track) }
            .map { $0.bitrate ?? 0 }
        if let highestOtherBitrate = comparableBitrates.max(), (track.bitrate ?? 0) > highestOtherBitrate {
            reasons.append("higher bitrate")
        }
        if metadataCompleteness(track) == tracks.map(metadataCompleteness).max(),
           tracks.contains(where: { metadataCompleteness($0) < metadataCompleteness(track) }) {
            reasons.append("more complete metadata")
        }
        if track.organizedPath?.isEmpty == false,
           tracks.contains(where: { $0.organizedPath?.isEmpty != false }) {
            reasons.append("local library copy")
        }
        return reasons
    }

    private static func isLossless(_ track: Track) -> Bool {
        ["flac", "alac", "wav", "aiff", "aif"].contains(track.format.lowercased())
    }

    private static func metadataCompleteness(_ track: Track) -> Int {
        [track.artist, track.albumArtist, track.album, track.title]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
            + (track.genre?.isEmpty == false ? 1 : 0)
            + (track.year == nil ? 0 : 1)
    }
}
