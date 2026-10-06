import Foundation
import GRDB

/// Protocol seam for the import service, allowing test fakes.
protocol ImportServicing: Sendable {
    func importDirectory(
        _ directory: URL,
        onProgress: (@Sendable (ImportService.ImportProgress) -> Void)?
    ) async throws -> ImportService.ImportResult

    /// Import these audio files (Finder files dropped on MLM, W2-H) — the same pipeline as a
    /// directory after its scan.
    func importFiles(
        _ audioFiles: [URL],
        onProgress: (@Sendable (ImportService.ImportProgress) -> Void)?
    ) async throws -> ImportService.ImportResult
}

/// The library folder changed from `oldRoot` to `newRoot` (S-SET-LIBFOLDER, W3-SET B2): a scanned
/// file whose place relative to the new folder matches a known track is that track — its
/// `original_path` is re-pointed instead of a second row being added.
struct LibraryRootRemap: Sendable, Equatable {
    let oldRoot: String
    let newRoot: String

    /// `x/y.m4a` for a file below `newRoot`, else `nil`.
    func relativePath(of path: String) -> String? {
        let root = Self.trimmed(newRoot)
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// The same place below the old folder.
    func oldAbsolutePath(forRelative relative: String) -> String {
        Self.trimmed(oldRoot) + "/" + relative
    }

    private static func trimmed(_ root: String) -> String {
        let standardized = (root as NSString).standardizingPath
        return standardized.hasSuffix("/") && standardized.count > 1 ? String(standardized.dropLast()) : standardized
    }
}

extension ImportServicing {
    /// A scan of the new library folder after a folder change (W3-SET B2). Services without a
    /// re-point step (test fakes) scan as usual.
    func importDirectory(
        _ directory: URL,
        remap: LibraryRootRemap?,
        onProgress: (@Sendable (ImportService.ImportProgress) -> Void)?
    ) async throws -> ImportService.ImportResult {
        try await importDirectory(directory, onProgress: onProgress)
    }

    /// Services that only import directories (test fakes) import no loose files.
    func importFiles(
        _ audioFiles: [URL],
        onProgress: (@Sendable (ImportService.ImportProgress) -> Void)?
    ) async throws -> ImportService.ImportResult {
        throw ImportService.ImportError.noAudioFiles
    }
}

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
        /// Whether cancellation stopped saving or analysis enqueueing.
        let cancelled: Bool
        /// Number of tracks committed before cancellation, if any.
        let committed: Int
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
        try await importDirectory(directory, remap: nil, onProgress: onProgress)
    }

    /// `importDirectory` after a library-folder change: files that are known tracks at their
    /// place relative to the new folder are re-pointed, not added (W3-SET B2).
    func importDirectory(
        _ directory: URL,
        remap: LibraryRootRemap?,
        onProgress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> ImportResult {
        // Phase 1: Scan for audio files
        onProgress?(ImportProgress(total: 0, processed: 0, phase: "Scanning…", currentFile: nil))
        let audioFiles = try Self.scanDirectory(directory)
        try Task.checkCancellation()
        return try await importFiles(audioFiles, remap: remap, onProgress: onProgress)
    }

    /// Phases 2–4 for a list of audio files (a scanned directory, or files dropped from Finder):
    /// extract, sanitize, insert. Files already in the library are skipped and counted.
    func importFiles(
        _ audioFiles: [URL],
        onProgress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> ImportResult {
        try await importFiles(audioFiles, remap: nil, onProgress: onProgress)
    }

    private func importFiles(
        _ audioFiles: [URL],
        remap: LibraryRootRemap?,
        onProgress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> ImportResult {
        guard !audioFiles.isEmpty else {
            return ImportResult(succeeded: 0, failed: 0, skipped: 0, failures: [], totalScanned: 0, cancelled: false, committed: 0)
        }

        onProgress?(ImportProgress(
            total: audioFiles.count,
            processed: 0,
            phase: "Extracting metadata…",
            currentFile: nil
        ))

        // Phase 2: Extract metadata in parallel using TaskGroup
        var extractionResults: [(URL, Result<TrackMetadata, Error>)] = []
        extractionResults.reserveCapacity(audioFiles.count)

        // Process in concurrent chunks to limit memory pressure
        let chunkSize = 50
        var processed = 0

        for chunk in audioFiles.chunked(into: chunkSize) {
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            processed += chunk.count

            onProgress?(ImportProgress(
                total: audioFiles.count,
                processed: processed,
                phase: "Extracting metadata…",
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
            phase: "Saving to the library…",
            currentFile: nil
        ))

        // Phase 3: Batch insert into database
        guard !Task.isCancelled else {
            return ImportResult(succeeded: 0, failed: failures.count, skipped: 0, failures: failures, totalScanned: audioFiles.count, cancelled: true, committed: 0)
        }
        let (succeeded, skipped, dbFailures, insertedTracks, wasCancelled) = await saveBatches(successfulMetadata, remap: remap)
        failures.append(contentsOf: dbFailures)

        onProgress?(ImportProgress(
            total: audioFiles.count,
            processed: audioFiles.count,
            phase: "Complete",
            currentFile: nil
        ))

        // Enqueue only work that was committed before cancellation.
        var enqueueCancelled = wasCancelled
        for track in insertedTracks {
            if Task.isCancelled {
                enqueueCancelled = true
                break
            }
            await PerformanceQueueService.shared.enqueueAnalysis(track: track)
        }

        return ImportResult(
            succeeded: succeeded,
            failed: failures.count,
            skipped: skipped,
            failures: failures,
            totalScanned: audioFiles.count,
            cancelled: enqueueCancelled,
            committed: succeeded
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
    func saveBatches(_ metadata: [TrackMetadata], remap: LibraryRootRemap? = nil) async -> (Int, Int, [String], [Track], Bool) {
        var totalSucceeded = 0
        var totalSkipped = 0
        var totalRepointed = 0
        defer {
            if totalRepointed > 0 {
                AppLogger.shared.info("Import after a library-folder change: \(totalRepointed) re-pointed", source: "Import")
            }
        }
        var failures: [String] = []
        var allInsertedTracks: [Track] = []

        for batch in metadata.chunked(into: Self.batchSize) {
            if Task.isCancelled {
                return (totalSucceeded, totalSkipped, failures, allInsertedTracks, true)
            }
            do {
                let (succeeded, skipped, insertedTracks, repointed) = try await saveBatch(batch, remap: remap)
                totalSucceeded += succeeded
                // A re-pointed file is already in the library.
                totalSkipped += skipped + repointed
                totalRepointed += repointed
                allInsertedTracks.append(contentsOf: insertedTracks)
            } catch {
                failures.append("Database error for batch of \(batch.count): \(error.localizedDescription)")
            }
        }

        return (totalSucceeded, totalSkipped, failures, allInsertedTracks, Task.isCancelled)
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
    private func saveBatch(_ batch: [TrackMetadata], remap: LibraryRootRemap?) async throws -> (Int, Int, [Track], Int) {
        try await database.write { db in
            var succeeded = 0
            var skipped = 0
            var repointed = 0
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

                // After a library-folder change (W3-SET B2): the same place below the new folder
                // is a known track — its old-folder `original_path`, or its `organized_path`
                // (letter case ignored, as on the Mac's case-insensitive volumes). Re-point it;
                // nothing else of the row changes (no new row, `date_added` kept).
                if let remap, let relative = remap.relativePath(of: standardized) {
                    let old = remap.oldAbsolutePath(forRelative: relative)
                    let oldCandidates = Array(Set([old, old.precomposedStringWithCanonicalMapping,
                                                   old.decomposedStringWithCanonicalMapping]))
                    let relativeForms = Array(Set([relative, relative.precomposedStringWithCanonicalMapping,
                                                   relative.decomposedStringWithCanonicalMapping].map { $0.lowercased() }))
                    let marks = oldCandidates.map { _ in "?" }.joined(separator: ",")
                    let relMarks = relativeForms.map { _ in "?" }.joined(separator: ",")
                    var arguments = StatementArguments(oldCandidates)
                    arguments += StatementArguments(relativeForms)
                    if let id = try Int64.fetchOne(db, sql: """
                        SELECT id FROM tracks
                        WHERE original_path IN (\(marks)) OR lower(organized_path) IN (\(relMarks))
                        ORDER BY id LIMIT 1
                        """, arguments: arguments) {
                        try db.execute(sql: "UPDATE tracks SET original_path = ? WHERE id = ?",
                                       arguments: [metadata.originalPath, id])
                        repointed += 1
                        continue
                    }
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
                track.dateAddedLibrary = track.dateAdded
                track.searchText = DatabaseManager.foldedSearchText(
                    track.artist + " " + track.album + " " + track.title
                )

                do {
                    try track.insert(db)
                    succeeded += 1
                    // W4-1: a track with album text joins its album with the file's disc and
                    // track number (find-or-create by the same key as v50; no album = no row).
                    let newID = track.id ?? db.lastInsertedRowID
                    do {
                        try AlbumTrackRepository.linkImportedTrack(
                            db, trackID: newID, artist: metadata.artist, albumArtist: metadata.albumArtist,
                            album: metadata.album, year: metadata.year,
                            disc: metadata.discNumber, number: metadata.trackNumber)
                        track.albumId = try Int64.fetchOne(db, sql: "SELECT album_id FROM tracks WHERE id = ?", arguments: [newID])
                    } catch {
                        // The track is in; it only lacks its album link (a failed statement leaves the transaction usable).
                        AppLogger.shared.warn("Import: album link failed for \(metadata.originalPath): \(error.localizedDescription)",
                                              source: "Import")
                    }
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

            return (succeeded, skipped, insertedTracks, repointed)
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

extension ImportService: ImportServicing {}

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
