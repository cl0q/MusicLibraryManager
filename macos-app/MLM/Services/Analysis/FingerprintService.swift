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
    /// Uses `fpcalc -raw` to obtain the uncompressed int32 array — required for
    /// correct bit-level XOR comparison. The compressed base64 format from
    /// `fpcalc -json` (without -raw) is NOT suitable for direct XOR comparison.
    ///
    /// - Parameter path: Path to the audio file
    /// - Returns: Tuple of (raw fingerprint Data as little-endian int32 bytes, duration in seconds)
    func generateFingerprint(path: String) async throws -> (fingerprint: Data, duration: Int)? {
        guard let fpcalc = fpcalcPath else { return nil }

        let result = try await ProcessRunner.run(
            fpcalc,
            arguments: ["-raw", "-json", path]
        )

        guard result.isSuccess,
              let data = result.stdout.data(using: .utf8) else {
            return nil
        }

        let response = try JSONDecoder().decode(FpcalcRawResponse.self, from: data)
        
        // Encode int32 array as little-endian bytes for storage
        var rawData = Data(capacity: response.fingerprint.count * 4)
        for value in response.fingerprint {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { rawData.append(contentsOf: $0) }
        }
        
        return (rawData, Int(response.duration))
    }

    /// Batch fingerprint multiple tracks with true parallel processing.
    ///
    /// Uses a `ConcurrencyLimiter` to enforce exactly `workerCount` fpcalc
    /// subprocesses running at once. In turbo mode this saturates 80% of
    /// available CPU cores — each slot runs a blocking fpcalc process.
    ///
    /// - Parameters:
    ///   - tracks: Tracks to fingerprint
    ///   - repository: Analysis repository for saving results
    ///   - libraryRoot: The configured absolute library root directory
    ///   - turboMode: Enable turbo mode (80% core utilization, no cap)
    ///   - progressHandler: Optional progress callback
    /// - Returns: Count of successful and failed fingerprints
    func batchFingerprint(
        tracks: [Track],
        repository: AnalysisRepository,
        libraryRoot: String? = nil,
        turboMode: Bool = false,
        progressHandler: ((MaintenanceProgressTracker.ProgressState) -> Void)? = nil
    ) async -> (processed: Int, failed: Int, cancelled: Bool) {
        let tracker = MaintenanceProgressTracker(total: tracks.count, turboMode: turboMode, progressHandler: progressHandler)
        
        let workerCount = BatchControl.workerCount(turboMode: turboMode)
        let limiter = BatchControl.limiter(turboMode: turboMode)
        
        AppLogger.shared.info("Starting fingerprint batch: \(tracks.count) tracks, \(workerCount) workers (turbo: \(turboMode))", source: "Fingerprint")
        
        // Feed ALL tracks into a single task group. The ConcurrencyLimiter
        // ensures exactly `workerCount` fpcalc subprocesses run at once.
        let results: [Result<Void, Error>] = await withTaskGroup(of: Result<Void, Error>.self) { group in
            for track in tracks {
                group.addTask {
                    // Check cancellation before acquiring a slot
                    guard !tracker.isCancelled else {
                        return .failure(CancellationError())
                    }
                    return await limiter.run {
                        await self.processSingleFingerprint(
                            track: track,
                            repository: repository,
                            libraryRoot: libraryRoot,
                            tracker: tracker
                        )
                    }
                }
            }
            
            var collected: [Result<Void, Error>] = []
            collected.reserveCapacity(tracks.count)
            for await result in group {
                collected.append(result)
                // Early exit: stop collecting if cancelled
                if tracker.isCancelled { break }
            }
            return collected
        }
        
        var processed = 0
        var failed = 0
        for result in results {
            switch result {
            case .success: processed += 1
            case .failure: failed += 1
            }
        }
        
        AppLogger.shared.info("Fingerprint batch complete: \(processed) processed, \(failed) failed", source: "Fingerprint")
        return (processed, failed, tracker.isCancelled)
    }
    
    /// Process a single track fingerprint with progress tracking
    private func processSingleFingerprint(
        track: Track,
        repository: AnalysisRepository,
        libraryRoot: String?,
        tracker: MaintenanceProgressTracker
    ) async -> Result<Void, Error> {
        guard let trackId = track.id else {
            tracker.updateProgress(
                trackId: 0,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: false
            )
            return .failure(NSError(domain: "Fingerprint", code: -1, userInfo: [NSLocalizedDescriptionKey: "No track ID"]))
        }
        
        // Resolve the actual file path (organizedPath is relative to libraryRoot)
        let filePath: String?
        if let organized = track.organizedPath {
            let path: String
            if let root = libraryRoot, !root.isEmpty {
                path = URL(fileURLWithPath: root).appendingPathComponent(organized).path
            } else {
                path = organized
            }
            if FileManager.default.fileExists(atPath: path) {
                filePath = path
            } else if FileManager.default.fileExists(atPath: track.originalPath) {
                filePath = track.originalPath
            } else {
                filePath = nil
            }
        } else {
            filePath = track.isLocal && FileManager.default.fileExists(atPath: track.originalPath) ? track.originalPath : nil
        }
        
        guard let resolvedPath = filePath else {
            tracker.updateProgress(
                trackId: trackId,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: false
            )
            return .failure(NSError(domain: "Fingerprint", code: -1, userInfo: [NSLocalizedDescriptionKey: "No file path"]))
        }
        
        do {
            if let result = try await generateFingerprint(path: resolvedPath) {
                let fingerprint = Fingerprint(
                    trackId: trackId,
                    fingerprint: result.fingerprint,  // Already Data (little-endian int32 bytes)
                    durationSeconds: result.duration,
                    acoustid: nil,
                    musicbrainzRecordingId: nil,
                    fingerprintedAt: ISO8601DateFormatter().string(from: Date())
                )
                try await repository.saveFingerprint(fingerprint)
                
                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: true
                )
                
                AppLogger.shared.debug(
                    "Fingerprint [\(tracker.currentState.current)/\(tracker.currentState.total)] \(track.artist) - \(track.title) → saved (duration: \(result.duration)s)",
                    source: "Fingerprint"
                )
                
                return .success(())
            } else {
                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: false
                )
                return .failure(NSError(domain: "Fingerprint", code: -1, userInfo: [NSLocalizedDescriptionKey: "Fingerprint generation failed"]))
            }
        } catch {
            tracker.updateProgress(
                trackId: trackId,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: false
            )
            AppLogger.shared.log("Fingerprint failed for \(track.title): \(error)", level: .warning, source: "Fingerprint")
            return .failure(error)
        }
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

    /// Compare two raw Chromaprint fingerprints and return a similarity score (0.0-1.0).
    ///
    /// Fingerprints must be stored as little-endian int32 arrays (4 bytes per element).
    /// XOR is performed per uint32 value and non-matching bits are counted.
    /// Random unrelated songs score ~0.5; true duplicates score 0.95+.
    static func compareFingerprints(_ fp1: Data, _ fp2: Data) -> Double {
        guard !fp1.isEmpty, !fp2.isEmpty else { return 0.0 }
        
        // Each fingerprint element is 4 bytes (uint32 little-endian)
        let count1 = fp1.count / 4
        let count2 = fp2.count / 4
        let minCount = min(count1, count2)
        guard minCount > 0 else { return 0.0 }

        var matchingBits = 0
        var totalBits = 0

        fp1.withUnsafeBytes { ptr1 in
            fp2.withUnsafeBytes { ptr2 in
                let ints1 = ptr1.bindMemory(to: UInt32.self)
                let ints2 = ptr2.bindMemory(to: UInt32.self)
                for i in 0..<minCount {
                    let xor = ints1[i] ^ ints2[i]
                    let diffBits = xor.nonzeroBitCount
                    matchingBits += 32 - diffBits
                    totalBits += 32
                }
            }
        }

        return Double(matchingBits) / Double(totalBits)
    }

    /// Whether two fingerprints indicate duplicates.
    ///
    /// Threshold of 0.85 is appropriate for Chromaprint int32 XOR comparison:
    /// - Random pairs score ~0.50 (50% of bits match by chance)
    /// - True duplicates (same recording) score 0.90–1.00
    /// - Different songs from same album/genre score 0.50–0.70
    static func areDuplicates(_ fp1: Data, _ fp2: Data, threshold: Double = 0.85) -> Bool {
        compareFingerprints(fp1, fp2) >= threshold
    }
}

// MARK: - Response Models

private struct FpcalcRawResponse: Codable {
    let fingerprint: [UInt32]
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
