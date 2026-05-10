import Foundation

/// Audio fingerprinting service using `fpcalc` (Chromaprint CLI).
///
/// Generates audio fingerprints for duplicate detection and AcoustID lookups.
/// Mirrors the Rust `FingerprintService` from `fingerprint/chromaprint.rs`.
final class FingerprintService: Sendable {
    private let fpcalcPath: String?

    /// AcoustID API endpoint.
    private static let acoustIdURL = "https://api.acoustid.org/v2/lookup"

    init() {
        self.fpcalcPath = ProcessRunner.findExecutable("fpcalc")
    }

    /// Whether `fpcalc` is available on this system.
    var isAvailable: Bool { fpcalcPath != nil }

    // MARK: - Fingerprint Generation

    /// Generate a Chromaprint fingerprint for an audio file.
    ///
    /// - Parameter path: Path to the audio file
    /// - Returns: Tuple of (compressed fingerprint string, duration in seconds)
    func generateFingerprint(path: String) async throws -> (fingerprint: String, duration: Int)? {
        guard let fpcalc = fpcalcPath else { return nil }

        let result = try await ProcessRunner.run(
            fpcalc,
            arguments: ["-json", path]
        )

        guard result.isSuccess,
              let data = result.stdout.data(using: .utf8) else {
            return nil
        }

        let response = try JSONDecoder().decode(FpcalcResponse.self, from: data)
        return (response.fingerprint, Int(response.duration))
    }

    /// Batch fingerprint multiple tracks.
    ///
    /// - Parameters:
    ///   - tracks: Tracks to fingerprint
    ///   - repository: Analysis repository for saving results
    ///   - onProgress: Progress callback (index, total)
    /// - Returns: Count of successful and failed fingerprints
    func batchFingerprint(
        tracks: [Track],
        repository: AnalysisRepository,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> (processed: Int, failed: Int) {
        var processed = 0
        var failed = 0

        for (index, track) in tracks.enumerated() {
            onProgress?(index, tracks.count)

            guard let trackId = track.id else {
                failed += 1
                continue
            }

            // Resolve the actual file path
            guard let filePath = track.organizedPath ?? (track.isLocal ? track.originalPath : nil) else {
                failed += 1
                continue
            }

            do {
                if let result = try await generateFingerprint(path: filePath) {
                    let fingerprint = Fingerprint(
                        trackId: trackId,
                        fingerprint: result.fingerprint.data(using: .utf8) ?? Data(),
                        durationSeconds: result.duration,
                        acoustid: nil,
                        musicbrainzRecordingId: nil,
                        fingerprintedAt: ISO8601DateFormatter().string(from: Date())
                    )
                    try await repository.saveFingerprint(fingerprint)
                    processed += 1
                } else {
                    failed += 1
                }
            } catch {
                failed += 1
                AppLogger.shared.log("Fingerprint failed for \(track.title): \(error)", level: .warning, source: "Fingerprint")
            }
        }

        return (processed, failed)
    }

    // MARK: - AcoustID Lookup

    /// Look up a fingerprint on AcoustID to find MusicBrainz recording ID.
    func lookupAcoustID(
        fingerprint: String,
        duration: Int,
        repository: AnalysisRepository,
        trackId: Int64
    ) async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["ACOUSTID_API_KEY"] else {
            return  // No API key configured
        }

        var request = URLRequest(url: URL(string: Self.acoustIdURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "client=\(apiKey)&meta=recordings+releasegroups+compress&fingerprint=\(fingerprint)&duration=\(duration)"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(AcoustIdResponse.self, from: data)

        guard response.status == "ok",
              let firstResult = response.results?.first,
              let recording = firstResult.recordings?.first else {
            return
        }

        // Update the fingerprint record with AcoustID info
        if var fp = try await repository.fetchFingerprint(trackId: trackId) {
            fp.acoustid = firstResult.id
            fp.musicbrainzRecordingId = recording.id
            try await repository.saveFingerprint(fp)
        }
    }

    // MARK: - Fingerprint Comparison

    /// Compare two fingerprints and return a similarity score (0.0-1.0).
    ///
    /// Uses bitwise comparison of fingerprint data — counts matching bits
    /// as a ratio of total bits.
    static func compareFingerprints(_ fp1: Data, _ fp2: Data) -> Double {
        guard !fp1.isEmpty, !fp2.isEmpty else { return 0.0 }

        let bytes1 = [UInt8](fp1)
        let bytes2 = [UInt8](fp2)
        let minLen = min(bytes1.count, bytes2.count)
        guard minLen > 0 else { return 0.0 }

        var matchingBits = 0
        var totalBits = 0

        for i in 0..<minLen {
            let xor = bytes1[i] ^ bytes2[i]
            let diffBits = xor.nonzeroBitCount
            matchingBits += 8 - diffBits
            totalBits += 8
        }

        return Double(matchingBits) / Double(totalBits)
    }

    /// Whether two fingerprints indicate duplicates (score >= threshold).
    static func areDuplicates(_ fp1: Data, _ fp2: Data, threshold: Double = 0.4) -> Bool {
        compareFingerprints(fp1, fp2) >= threshold
    }
}

// MARK: - Response Models

private struct FpcalcResponse: Codable {
    let fingerprint: String
    let duration: Double
}

struct AcoustIdResponse: Codable {
    let status: String
    let results: [AcoustIdResult]?
}

struct AcoustIdResult: Codable {
    let id: String
    let score: Double?
    let recordings: [AcoustIdRecording]?
}

struct AcoustIdRecording: Codable {
    let id: String
    let title: String?
    let artists: [AcoustIdArtist]?
}

struct AcoustIdArtist: Codable {
    let id: String
    let name: String
}
