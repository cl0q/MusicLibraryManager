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

    private struct ScoredMatch {
        var match: DuplicateReviewMatch
        var fingerprintSimilarity: Double
        var titleSimilarity: Double
        var artistSimilarity: Double
        var fieldScores: [String: Double]
        var conflictingFields: [String]
        var isVariant: Bool

        var evidence: ReviewPairEvidence {
            ReviewPairEvidence(
                trackAId: match.trackAId,
                trackBId: match.trackBId,
                fingerprintSimilarity: fingerprintSimilarity,
                titleSimilarity: titleSimilarity,
                artistSimilarity: artistSimilarity,
                conflictingFields: conflictingFields,
                isVariant: isVariant
            )
        }
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

        // Blocking: instead of comparing all O(n²) pairs (60M+ for an 11k
        // library, which is why the scan ran to "21 million of 11000" and
        // never finished), only compare tracks whose duration is within a
        // small tolerance window. Two copies of the same recording have
        // near-identical length, so this preserves recall while cutting the
        // candidate set to a tiny fraction.
        let durationTolerance = 2  // seconds
        var byDuration: [Int: [Int]] = [:]  // duration bucket -> indices into trackList
        var noDuration: [Int] = []
        for (idx, track) in trackList.enumerated() {
            if let d = track.duration, d > 0 {
                byDuration[d, default: []].append(idx)
            } else {
                noDuration.append(idx)
            }
        }

        // Build the unique candidate-pair set within the tolerance window.
        var candidatePairs: [(Int, Int)] = []
        var seen = Set<Int64>()  // encodes (min<<32 | max) to dedupe
        func addPair(_ a: Int, _ b: Int) {
            let lo = min(a, b), hi = max(a, b)
            let key = Int64(lo) << 32 | Int64(hi)
            if seen.insert(key).inserted {
                candidatePairs.append((lo, hi))
            }
        }
        for (bucket, indices) in byDuration {
            // Pairs inside this bucket.
            for a in 0..<indices.count {
                for b in (a + 1)..<indices.count {
                    addPair(indices[a], indices[b])
                }
            }
            // Pairs between this bucket and the higher neighbour buckets
            // (within the duration tolerance window).
            let neighbours = (1...durationTolerance).flatMap { byDuration[bucket + $0] ?? [] }
            for a in indices {
                for b in neighbours {
                    addPair(a, b)
                }
            }
        }
        // Tracks with unknown duration: only compare among themselves (rare,
        // and keeps the explosion contained).
        for a in 0..<noDuration.count {
            for b in (a + 1)..<noDuration.count {
                addPair(noDuration[a], noDuration[b])
            }
        }

        let totalPairs = candidatePairs.count

        AppLogger.shared.info("Starting deep scan: \(trackList.count) tracks, \(totalPairs) candidate pairs (duration-blocked, turbo: \(turboMode))", source: "Dedup")

        // Re-anchor the progress tracker to the real work unit (pairs), not
        // the track count — otherwise the UI shows "21M of 11000".
        tracker.reset(total: totalPairs)

        var pairIndex = 0
        var matches: [ScoredMatch] = []
        for (i, j) in candidatePairs {
            pairIndex += 1

            if tracker.isCancelled || Task.isCancelled {
                AppLogger.shared.info("Deep scan cancelled at \(result.pairsCompared) pairs", source: "Dedup")
                return result
            }

            if pairIndex == 1 ||
                pairIndex == totalPairs ||
                pairIndex % BatchControl.batchSize(turboMode: turboMode) == 0 {
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

            let fieldScores = Self.metadataScores(trackA: trackA, trackB: trackB, title: titleSim, artist: artistSim)
            let conflictingFields = fieldScores.compactMap { field, score in
                score < Self.metadataAgreementThreshold ? field : nil
            }.sorted()
            let isVariant = DuplicateMatcher.isVariant(
                title1: trackA.title,
                artist1: trackA.artist,
                title2: trackB.title,
                artist2: trackB.artist
            )
            matches.append(ScoredMatch(
                match: DuplicateReviewMatch(trackAId: idA, trackBId: idB),
                fingerprintSimilarity: score,
                titleSimilarity: titleSim,
                artistSimilarity: artistSim,
                fieldScores: fieldScores,
                conflictingFields: conflictingFields,
                isVariant: isVariant
            ))
        }

        guard !tracker.isCancelled, !Task.isCancelled else {
            AppLogger.shared.info("Deep scan cancelled before persisting proposals", source: "Dedup")
            return result
        }

        let reviewItems = reviewItems(from: matches, tracks: trackList)
        result.duplicatesFound = reviewItems.filter { $0.actionType == "fingerprint_dedup" }.count
        result.conflictsFlagged = reviewItems.filter { $0.actionType == "metadata_conflict" }.count

        // A scan only proposes complete groups. Replacing the previous pending
        // proposals prevents duplicate cards after a re-scan; resolved history
        // remains untouched. The repository rolls back the replacement if
        // cancellation races the final write.
        // Decided groups are dropped there (IMP-051): the counts are what was proposed.
        let proposed = try await analysisRepository.replacePendingScanReviewItems(reviewItems) {
            tracker.isCancelled || Task.isCancelled
        }
        result.duplicatesFound = proposed.duplicates
        result.conflictsFlagged = proposed.conflicts

        AppLogger.shared.log(
            "Deep scan: \(result.pairsCompared) pairs, \(result.duplicatesFound) dups, \(result.conflictsFlagged) conflicts",
            source: "Dedup"
        )
        return result
    }

    // MARK: - Review Queue

    private func reviewItems(from matches: [ScoredMatch], tracks: [Track]) -> [ReviewItem] {
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
            track.id.map { ($0, track) }
        })

        return DuplicateReviewGrouping.groups(matches: matches.map(\.match)).compactMap { group in
            let memberIDs = Set(group.memberTrackIds)
            let groupMatches = matches
                .filter { memberIDs.contains($0.match.trackAId) && memberIDs.contains($0.match.trackBId) }
                .sorted(by: scoredMatchOrder)
            let groupTracks = group.memberTrackIds.compactMap { tracksByID[$0] }
            guard let primaryEvidence = groupMatches.first, groupTracks.count > 1 else { return nil }

            let isVariant = groupMatches.contains(where: \.isVariant)
            let conflictingFields = Array(Set(groupMatches.flatMap(\.conflictingFields))).sorted()
            let recommendation = DuplicateReviewRecommendation.recommendation(
                for: groupTracks,
                keepBoth: isVariant
            )
            let primaryTrackID = recommendation?.trackId ?? group.memberTrackIds[0]
            let relatedTrackID = group.memberTrackIds.first { $0 != primaryTrackID }
            let trackA = tracksByID[primaryEvidence.match.trackAId].map(ReviewTrackSnapshot.init(track:))
            let trackB = tracksByID[primaryEvidence.match.trackBId].map(ReviewTrackSnapshot.init(track:))
            let details = ReviewDetails(
                groupKey: group.key,
                evidence: ReviewEvidence(
                    fingerprintSimilarity: primaryEvidence.fingerprintSimilarity,
                    pairs: groupMatches.map(\.evidence)
                ),
                fieldScores: ReviewFieldScores(
                    titleSimilarity: groupMatches.map(\.titleSimilarity).min(),
                    artistSimilarity: groupMatches.map(\.artistSimilarity).min(),
                    scores: Self.groupFieldScores(groupMatches)
                ),
                conflictingFields: conflictingFields,
                variant: ReviewVariant(
                    isVariant: isVariant,
                    explanation: isVariant ? "Same recording, different version" : nil
                ),
                recommendation: recommendation,
                tracks: groupTracks.map(ReviewTrackSnapshot.init(track:)),
                similarityScore: primaryEvidence.fingerprintSimilarity,
                trackA: trackA,
                trackB: trackB
            )

            let actionType = !isVariant && !conflictingFields.isEmpty
                ? "metadata_conflict"
                : "fingerprint_dedup"
            return ReviewItem(
                id: nil,
                actionType: actionType,
                groupKey: group.key,
                trackId: primaryTrackID,
                relatedTrackId: relatedTrackID,
                details: (try? details.encodedJSON()) ?? "{}",
                autoAction: nil,
                status: "pending",
                createdAt: nil,
                resolvedAt: nil
            )
        }
    }

    private func scoredMatchOrder(_ lhs: ScoredMatch, _ rhs: ScoredMatch) -> Bool {
        if lhs.fingerprintSimilarity != rhs.fingerprintSimilarity {
            return lhs.fingerprintSimilarity > rhs.fingerprintSimilarity
        }
        if lhs.match.trackAId != rhs.match.trackAId { return lhs.match.trackAId < rhs.match.trackAId }
        return lhs.match.trackBId < rhs.match.trackBId
    }

    private static func metadataScores(
        trackA: Track,
        trackB: Track,
        title: Double,
        artist: Double
    ) -> [String: Double] {
        [
            ReviewMetadataField.title.rawValue: title,
            ReviewMetadataField.artist.rawValue: artist,
            ReviewMetadataField.albumArtist.rawValue: stringSimilarity(trackA.albumArtist, trackB.albumArtist),
            ReviewMetadataField.album.rawValue: stringSimilarity(trackA.album, trackB.album),
            ReviewMetadataField.genre.rawValue: optionalStringSimilarity(trackA.genre, trackB.genre),
            ReviewMetadataField.year.rawValue: trackA.year == trackB.year ? 1 : 0,
        ]
    }

    private static func groupFieldScores(_ matches: [ScoredMatch]) -> [String: Double] {
        var grouped: [String: [Double]] = [:]
        for match in matches {
            for (field, score) in match.fieldScores {
                grouped[field, default: []].append(score)
            }
        }
        return grouped.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value.min() ?? 1
        }
    }

    private static func stringSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let normalizedLHS = DeduplicationNormalizer.normalize(lhs)
        let normalizedRHS = DeduplicationNormalizer.normalize(rhs)
        if normalizedLHS.isEmpty && normalizedRHS.isEmpty { return 1 }
        return DuplicateMatcher.jaroWinkler(normalizedLHS, normalizedRHS)
    }

    private static func optionalStringSimilarity(_ lhs: String?, _ rhs: String?) -> Double {
        stringSimilarity(lhs ?? "", rhs ?? "")
    }
}
