import Foundation
import GRDB

/// Recursive directory scanner and batch importer.
///
/// Scans a directory tree for audio files, extracts metadata from each,
/// generates organized paths, and inserts tracks into the database.
///
/// ## Import Pipeline
/// 1. **Scan** — Recursively find all audio files
/// 2. **Extract** — Read metadata from each file (parallel with TaskGroup)
/// 3. **Sanitize** — Generate FAT32-safe organized paths
/// 4. **Insert** — Batch-insert tracks into SQLite
///
/// ## Error Handling
/// Uses continue-on-error pattern — individual file failures are collected
/// but don't stop the import. Matches the Tauri app's `import/importer.rs`.
final class ImportService: Sendable {
    private let database: DatabasePool
    private let trackRepository: TrackRepository

    /// Batch size for database transactions.
    private static let batchSize = 500

    init(database: DatabasePool, trackRepository: TrackRepository) {
        self.database = database
        self.trackRepository = trackRepository
    }

    // MARK: - Result Type

    /// Result of a batch import operation.
    struct ImportResult: Sendable {
        /// Number of successfully imported tracks.
        let succeeded: Int
        /// Number of failed imports.
        let failed: Int
        /// Number of files skipped (already in database).
        let skipped: Int
        /// Detailed error messages for each failure.
        let failures: [String]
        /// Total files scanned.
        let totalScanned: Int
    }

    /// Progress update during import.
    struct ImportProgress: Sendable {
        /// Total files to process.
        let total: Int
        /// Files processed so far.
        let processed: Int
        /// Current phase description.
        let phase: String
        /// Current file being processed (if applicable).
        let currentFile: String?

        /// Progress fraction 0.0 → 1.0
        var fraction: Double {
            total > 0 ? Double(processed) / Double(total) : 0
        }
    }

    // MARK: - Scanning

    /// Recursively scan a directory for audio files.
    ///
    /// Traverses the directory tree depth-first, collecting paths to all
    /// supported audio files. Subdirectories are scanned automatically.
    /// Matches the Tauri app's `import/scanner.rs` behavior.
    ///
    /// - Parameter directory: Root directory to scan
    /// - Returns: Sorted list of audio file URLs
    /// - Throws: If the directory cannot be read
    static func scanDirectory(_ directory: URL) throws -> [URL] {
        let fm = FileManager.default

        guard fm.fileExists(atPath: directory.path) else {
            throw ImportError.directoryNotFound(directory.path)
        }

        var audioFiles: [URL] = []
        scanDirectoryRecursive(directory, into: &audioFiles)

        // Sort for deterministic output (matches Rust scanner)
        audioFiles.sort { $0.path < $1.path }

        return audioFiles
    }

    /// Internal recursive scanner.
    private static func scanDirectoryRecursive(_ directory: URL, into files: inout [URL]) {
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isReadableKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in contents {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDirectory {
                scanDirectoryRecursive(url, into: &files)
            } else if MetadataExtractor.isAudioFile(url) {
                files.append(url)
            }
        }
    }

    // MARK: - Import

    /// Import audio files from a directory into the database.
    ///
    /// Full pipeline: scan → extract metadata → generate paths → insert.
    ///
    /// - Parameters:
    ///   - directory: Root directory to scan for audio files
    ///   - onProgress: Progress callback (called on main actor)
    /// - Returns: Import result with success/failure counts
    func importDirectory(
        _ directory: URL,
        onProgress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> ImportResult {
        // Phase 1: Scan for audio files
        onProgress?(ImportProgress(total: 0, processed: 0, phase: "Scanning...", currentFile: nil))
        let audioFiles = try Self.scanDirectory(directory)

        guard !audioFiles.isEmpty else {
            return ImportResult(succeeded: 0, failed: 0, skipped: 0, failures: [], totalScanned: 0)
        }

        onProgress?(ImportProgress(
            total: audioFiles.count,
            processed: 0,
            phase: "Extracting metadata...",
            currentFile: nil
        ))

        // Phase 2: Extract metadata in parallel using TaskGroup
        var extractionResults: [(URL, Result<TrackMetadata, Error>)] = []
        extractionResults.reserveCapacity(audioFiles.count)

        // Process in concurrent chunks to limit memory pressure
        let chunkSize = 50
        var processed = 0

        for chunk in audioFiles.chunked(into: chunkSize) {
            let chunkResults = await withTaskGroup(
                of: (URL, Result<TrackMetadata, Error>).self,
                returning: [(URL, Result<TrackMetadata, Error>)].self
            ) { group in
                for url in chunk {
                    group.addTask {
                        do {
                            let metadata = try await MetadataExtractor.extract(from: url)
                            return (url, .success(metadata))
                        } catch {
                            return (url, .failure(error))
                        }
                    }
                }

                var results: [(URL, Result<TrackMetadata, Error>)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            extractionResults.append(contentsOf: chunkResults)
            processed += chunk.count

            onProgress?(ImportProgress(
                total: audioFiles.count,
                processed: processed,
                phase: "Extracting metadata...",
                currentFile: chunk.last?.lastPathComponent
            ))
        }

        // Separate successes and failures
        var successfulMetadata: [TrackMetadata] = []
        var failures: [String] = []

        for (url, result) in extractionResults {
            switch result {
            case .success(let metadata):
                successfulMetadata.append(metadata)
            case .failure(let error):
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        onProgress?(ImportProgress(
            total: audioFiles.count,
            processed: audioFiles.count,
            phase: "Saving to database...",
            currentFile: nil
        ))

        // Phase 3: Batch insert into database
        let (succeeded, skipped, dbFailures, insertedTracks) = await saveBatches(successfulMetadata)
        failures.append(contentsOf: dbFailures)

        onProgress?(ImportProgress(
            total: audioFiles.count,
            processed: audioFiles.count,
            phase: "Complete",
            currentFile: nil
        ))

        // Enqueue successfully imported tracks for background analysis
        for track in insertedTracks {
            await PerformanceQueueService.shared.enqueueAnalysis(track: track)
        }

        return ImportResult(
            succeeded: succeeded,
            failed: failures.count,
            skipped: skipped,
            failures: failures,
            totalScanned: audioFiles.count
        )
    }

    // MARK: - Database Operations

    /// Save metadata batches to the database.
    ///
    /// Processes in chunks matching the Rust importer's BATCH_SIZE (500).
    /// Each batch runs in an atomic transaction.
    ///
    /// - Parameter metadata: Array of extracted metadata
    /// - Returns: (succeeded count, skipped count, failure messages, successfully inserted tracks)
    private func saveBatches(_ metadata: [TrackMetadata]) async -> (Int, Int, [String], [Track]) {
        var totalSucceeded = 0
        var totalSkipped = 0
        var failures: [String] = []
        var allInsertedTracks: [Track] = []

        for batch in metadata.chunked(into: Self.batchSize) {
            do {
                let (succeeded, skipped, insertedTracks) = try await saveBatch(batch)
                totalSucceeded += succeeded
                totalSkipped += skipped
                allInsertedTracks.append(contentsOf: insertedTracks)
            } catch {
                failures.append("Database error for batch of \(batch.count): \(error.localizedDescription)")
            }
        }

        return (totalSucceeded, totalSkipped, failures, allInsertedTracks)
    }

    /// Save a single batch of metadata within a transaction.
    ///
    /// Generates organized paths and inserts tracks. Skips tracks whose
    /// `original_path` already exists. Existence is checked against three
    /// normalisations of the path so a rescan does not create duplicate
    /// rows (with a fresh `date_added`) when the same file is encountered
    /// under a slightly different Unicode form or path-standardisation —
    /// the prior single-string `==` check missed those.
    ///
    /// - Parameter batch: Metadata to insert
    /// - Returns: (succeeded count, skipped count, successfully inserted tracks)
    private func saveBatch(_ batch: [TrackMetadata]) async throws -> (Int, Int, [Track]) {
        try await database.write { db in
            var succeeded = 0
            var skipped = 0
            var insertedTracks: [Track] = []

            for metadata in batch {
                // Build path variants: raw, standardized (resolves "//" etc),
                // and Unicode-normalised (NFC + NFD). Most macOS path APIs
                // emit NFD ("Aaron" Composed vs Decomposed for accented chars)
                // while user-typed/library paths are usually NFC. Comparing
                // only `==` against the DB-stored path misses this.
                let raw = metadata.originalPath
                let standardized = (raw as NSString).standardizingPath
                let nfc = raw.precomposedStringWithCanonicalMapping
                let nfd = raw.decomposedStringWithCanonicalMapping
                let stdNFC = standardized.precomposedStringWithCanonicalMapping
                let stdNFD = standardized.decomposedStringWithCanonicalMapping

                var candidates = [raw, standardized, nfc, nfd, stdNFC, stdNFD]
                candidates = Array(Set(candidates))  // dedupe

                let exists = try Track
                    .filter(candidates.contains(Track.Columns.originalPath))
                    .fetchCount(db) > 0

                if exists {
                    skipped += 1
                    continue
                }

                // Generate organized path
                let organizedPath = PathSanitizer.organizedPath(for: metadata)

                // Create track record
                var track = Track(
                    artist: metadata.artist,
                    albumArtist: metadata.albumArtist,
                    album: metadata.album,
                    title: metadata.title,
                    format: metadata.format,
                    originalPath: metadata.originalPath
                )
                track.genre = metadata.genre
                track.year = metadata.year
                track.bitrate = metadata.bitrate
                track.duration = metadata.duration
                track.organizedPath = organizedPath
                track.dateAdded = ISO8601DateFormatter().string(from: Date())
                track.searchText = DatabaseManager.foldedSearchText(
                    track.artist + " " + track.album + " " + track.title
                )

                do {
                    try track.insert(db)
                    succeeded += 1
                    insertedTracks.append(track)
                } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                    // A UNIQUE-constraint violation here means a row with
                    // this original_path already exists but slipped through
                    // the candidate match above (e.g. a normalisation we
                    // didn't anticipate). Treat as skip — do NOT clobber the
                    // existing row's date_added with a fresh insert.
                    AppLogger.shared.warn(
                        "Import: UNIQUE conflict for \(metadata.originalPath) — keeping existing row (date_added preserved)",
                        source: "Import"
                    )
                    skipped += 1
                }
            }

            return (succeeded, skipped, insertedTracks)
        }
    }

    // MARK: - Errors

    enum ImportError: Error, LocalizedError {
        case directoryNotFound(String)
        case noAudioFiles

        var errorDescription: String? {
            switch self {
            case .directoryNotFound(let path):
                return "Directory not found: \(path)"
            case .noAudioFiles:
                return "No audio files found in directory"
            }
        }
    }
}

// MARK: - Array Chunking Extension

extension Array {
    /// Split array into chunks of the given size.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
