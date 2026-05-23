import Foundation

/// String normalization for deduplication matching.
///
/// Mirrors the Rust `dedup/normalize.rs`. NFC normalize → lowercase →
/// remove non-alphanumeric → collapse whitespace. Artist normalization
/// additionally handles `&` → `feat`, `ft.` → `feat`, etc.
enum DeduplicationNormalizer {

    /// Normalize a string for comparison.
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping  // NFC normalize
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .reduce(into: "") { $0 += String($1) }
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Normalize an artist string (handles feat/ft/& conventions).
    static func normalizeArtist(_ artist: String) -> String {
        var text = artist

        // & → feat
        text = text.replacingOccurrences(
            of: #"\s+&\s+"#,
            with: " feat ",
            options: .regularExpression
        )

        // feat./ft./featuring/with → feat
        text = text.replacingOccurrences(
            of: #"(?i)\b(feat\.?|ft\.?|featuring|with)\b"#,
            with: "feat",
            options: .regularExpression
        )

        return normalize(text)
    }
}

/// Duplicate matcher combining metadata and fingerprint similarity.
///
/// Mirrors the Rust `dedup/matcher.rs`.
/// Weighting: 70% title + 30% artist (Jaro-Winkler distance).
enum DuplicateMatcher {

    // MARK: - Metadata Similarity

    /// Calculate similarity between two tracks based on metadata.
    ///
    /// Returns 0.0-1.0. Weighting: 70% title, 30% artist.
    static func calculateSimilarity(
        title1: String, artist1: String,
        title2: String, artist2: String
    ) -> Double {
        let normTitle1 = DeduplicationNormalizer.normalize(title1)
        let normTitle2 = DeduplicationNormalizer.normalize(title2)
        let normArtist1 = DeduplicationNormalizer.normalizeArtist(artist1)
        let normArtist2 = DeduplicationNormalizer.normalizeArtist(artist2)

        guard !normTitle1.isEmpty, !normTitle2.isEmpty,
              !normArtist1.isEmpty, !normArtist2.isEmpty else {
            return 0.0
        }

        let titleSim = jaroWinkler(normTitle1, normTitle2)
        let artistSim = jaroWinkler(normArtist1, normArtist2)

        return 0.7 * titleSim + 0.3 * artistSim
    }

    /// Check if two tracks are variants (remix, live, etc.) of each other.
    ///
    /// Artist similarity >= 0.90, one has variant keyword, base title similarity >= 0.85.
    static func isVariant(
        title1: String, artist1: String,
        title2: String, artist2: String
    ) -> Bool {
        let normArtist1 = DeduplicationNormalizer.normalizeArtist(artist1)
        let normArtist2 = DeduplicationNormalizer.normalizeArtist(artist2)

        guard jaroWinkler(normArtist1, normArtist2) >= 0.90 else { return false }

        let t1 = DeduplicationNormalizer.normalize(title1)
        let t2 = DeduplicationNormalizer.normalize(title2)

        let hasVariant1 = containsVariantKeyword(t1)
        let hasVariant2 = containsVariantKeyword(t2)

        // One must have variant keyword, other must not (or both have different ones)
        guard hasVariant1 || hasVariant2 else { return false }

        let base1 = stripVariantKeywords(t1)
        let base2 = stripVariantKeywords(t2)

        return jaroWinkler(base1, base2) >= 0.85
    }

    // MARK: - Variant Keywords

    private static let variantPattern = try! NSRegularExpression(
        pattern: #"\b(remix|edit|mix|version|live|acoustic|radio|extended|instrumental|vocal|dub|vip|bootleg|rework|remaster)\b"#,
        options: .caseInsensitive
    )

    private static func containsVariantKeyword(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return variantPattern.firstMatch(in: text, range: range) != nil
    }

    private static func stripVariantKeywords(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return variantPattern
            .stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Jaro-Winkler

    /// Jaro-Winkler string similarity (0.0-1.0).
    static func jaroWinkler(_ s1: String, _ s2: String) -> Double {
        if s1 == s2 { return 1.0 }
        if s1.isEmpty || s2.isEmpty { return 0.0 }

        let chars1 = Array(s1)
        let chars2 = Array(s2)
        let len1 = chars1.count
        let len2 = chars2.count

        let matchDistance = max(len1, len2) / 2 - 1
        guard matchDistance >= 0 else { return 0.0 }

        var matched1 = [Bool](repeating: false, count: len1)
        var matched2 = [Bool](repeating: false, count: len2)

        var matches = 0
        var transpositions = 0

        // Find matches
        for i in 0..<len1 {
            let start = max(0, i - matchDistance)
            let end = min(i + matchDistance + 1, len2)

            if start < end {
                for j in start..<end {
                    if matched2[j] || chars1[i] != chars2[j] { continue }
                    matched1[i] = true
                    matched2[j] = true
                    matches += 1
                    break
                }
            }
        }

        if matches == 0 { return 0.0 }

        // Count transpositions
        var k = 0
        for i in 0..<len1 {
            if !matched1[i] { continue }
            while k < len2 && !matched2[k] { k += 1 }
            if k < len2 {
                if chars1[i] != chars2[k] { transpositions += 1 }
                k += 1
            }
        }

        let jaro = (
            Double(matches) / Double(len1) +
            Double(matches) / Double(len2) +
            Double(matches - transpositions / 2) / Double(matches)
        ) / 3.0

        // Winkler modification
        var prefix = 0
        for i in 0..<min(4, min(len1, len2)) {
            if chars1[i] == chars2[i] { prefix += 1 }
            else { break }
        }

        return jaro + Double(prefix) * 0.1 * (1.0 - jaro)
    }
}

/// Deep scan service for finding fingerprint-based duplicates.
///
/// Mirrors the Rust `dedup/fingerprint.rs`.
final class DeepScanService {

    struct DeepScanResult {
        var pairsCompared: Int = 0
        var duplicatesFound: Int = 0
        var conflictsFlagged: Int = 0
    }

    /// Match threshold for fingerprint comparison.
    ///
    /// With correct Chromaprint int32 XOR comparison, random pairs score ~0.50.
    /// True duplicates (same recording) score 0.90–1.00.
    private static let fingerprintThreshold: Double = 0.85

    /// Metadata agreement threshold (Jaro-Winkler).
    ///
    /// Raised to 0.80 to cut down on noise conflicts from genre/album-mates.
    private static let metadataAgreementThreshold: Double = 0.80

    private let trackRepository: TrackRepository
    private let analysisRepository: AnalysisRepository

    init(trackRepository: TrackRepository, analysisRepository: AnalysisRepository) {
        self.trackRepository = trackRepository
        self.analysisRepository = analysisRepository
    }

    /// Run a deep scan comparing all fingerprinted tracks for duplicates with turbo mode.
    ///
    /// O(n²) comparison. For large libraries this can be slow.
    /// Turbo mode uses parallel processing for batch operations.
    func deepScan(
        turboMode: Bool = false,
        progressHandler: ((MaintenanceProgressTracker.ProgressState) -> Void)? = nil
    ) async throws -> DeepScanResult {
        let tracks = try await trackRepository.fetchFingerprintedTracks()
        var result = DeepScanResult()
        
        let tracker = MaintenanceProgressTracker(
            total: tracks.count,
            turboMode: turboMode,
            progressHandler: progressHandler
        )
        
        // Load all fingerprints
        var fingerprints: [Int64: Data] = [:]
        for track in tracks {
            guard let trackId = track.id else { continue }
            if let fp = try await analysisRepository.fetchFingerprint(trackId: trackId) {
                fingerprints[trackId] = fp.fingerprint
            }
        }

        let trackList = tracks.filter { fingerprints[$0.id ?? 0] != nil }
        let totalPairs = trackList.count * (trackList.count - 1) / 2

        AppLogger.shared.info("Starting deep scan: \(trackList.count) tracks, \(totalPairs) pairs (turbo: \(turboMode))", source: "Dedup")

        var pairIndex = 0
        for i in 0..<trackList.count {
            for j in (i + 1)..<trackList.count {
                pairIndex += 1
                
                if tracker.isCancelled {
                    AppLogger.shared.info("Deep scan cancelled at \(result.pairsCompared) pairs", source: "Dedup")
                    return result
                }
                
                if pairIndex % BatchControl.batchSize(turboMode: turboMode) == 0 {
                    tracker.updateProgress(
                        current: pairIndex,
                        trackId: 0,
                        trackTitle: "Comparing pairs",
                        trackArtist: "",
                        savedToDb: false
                    )
                }

                let trackA = trackList[i]
                let trackB = trackList[j]
                guard let idA = trackA.id, let idB = trackB.id,
                      let fpA = fingerprints[idA], let fpB = fingerprints[idB] else {
                    continue
                }

                result.pairsCompared += 1

                // Fingerprint similarity
                let score = FingerprintService.compareFingerprints(fpA, fpB)
                guard score >= Self.fingerprintThreshold else { continue }

                // Check metadata agreement
                let titleSim = DuplicateMatcher.jaroWinkler(
                    DeduplicationNormalizer.normalize(trackA.title),
                    DeduplicationNormalizer.normalize(trackB.title)
                )
                let artistSim = DuplicateMatcher.jaroWinkler(
                    DeduplicationNormalizer.normalizeArtist(trackA.artist),
                    DeduplicationNormalizer.normalizeArtist(trackB.artist)
                )

                if titleSim < Self.metadataAgreementThreshold || artistSim < Self.metadataAgreementThreshold {
                    // Metadata conflict — flag for review
                    try await flagForReview(
                        trackA: trackA, trackB: trackB,
                        score: score,
                        actionType: "metadata_conflict"
                    )
                    result.conflictsFlagged += 1
                } else {
                    // Auto-keep better quality
                    let (keepTrack, dupTrack) = isBetterQuality(trackA, trackB) ? (trackA, trackB) : (trackB, trackA)
                    try await trackRepository.markDuplicate(
                        trackId: dupTrack.id!,
                        variantOf: keepTrack.id!
                    )
                    try await flagForReview(
                        trackA: keepTrack, trackB: dupTrack,
                        score: score,
                        actionType: "fingerprint_dedup",
                        autoAction: "kept_higher_quality"
                    )
                    result.duplicatesFound += 1
                }
            }
        }

        AppLogger.shared.log(
            "Deep scan: \(result.pairsCompared) pairs, \(result.duplicatesFound) dups, \(result.conflictsFlagged) conflicts",
            source: "Dedup"
        )
        return result
    }

    // MARK: - Quality Comparison

    /// Determine if trackA has better quality than trackB.
    ///
    /// Lossless beats lossy. Same type → higher bitrate wins.
    private func isBetterQuality(_ a: Track, _ b: Track) -> Bool {
        let losslessFormats: Set<String> = ["flac", "alac", "wav", "aiff"]
        let aLossless = losslessFormats.contains(a.format.lowercased())
        let bLossless = losslessFormats.contains(b.format.lowercased())

        if aLossless && !bLossless { return true }
        if !aLossless && bLossless { return false }

        return (a.bitrate ?? 0) >= (b.bitrate ?? 0)
    }

    // MARK: - Review Queue

    private func flagForReview(
        trackA: Track, trackB: Track,
        score: Double,
        actionType: String,
        autoAction: String? = "flagged"
    ) async throws {
        let details: [String: Any] = [
            "similarity_score": score,
            "track_a": ["id": trackA.id ?? 0, "title": trackA.title, "artist": trackA.artist],
            "track_b": ["id": trackB.id ?? 0, "title": trackB.title, "artist": trackB.artist]
        ]
        let detailsJSON = String(data: try JSONSerialization.data(withJSONObject: details), encoding: .utf8) ?? "{}"

        let item = ReviewItem(
            id: nil,
            actionType: actionType,
            trackId: trackA.id ?? 0,
            relatedTrackId: trackB.id,
            details: detailsJSON,
            autoAction: autoAction,
            status: "pending",
            createdAt: nil,
            resolvedAt: nil
        )

        try await analysisRepository.saveReviewItem(item)
    }
}
