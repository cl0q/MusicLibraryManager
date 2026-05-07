import Testing
import GRDB
@testable import MLM

/// Tests for the Import & Metadata services (Phase 4).
///
/// Covers:
/// - PathSanitizer: FAT32-safe filename sanitization
/// - ImportService: Directory scanning + batch database insertion
/// - MetadataExtractor: Audio format support detection
struct ImportTests {

    // MARK: - PathSanitizer Tests

    @Test func sanitizeNormalFilename() {
        #expect(PathSanitizer.sanitizeFilename("My Song") == "My Song")
        #expect(PathSanitizer.sanitizeFilename("The Beatles") == "The Beatles")
    }

    @Test func sanitizeUnsafeCharacters() {
        // < > : " / \ | ? * replaced with _
        #expect(PathSanitizer.sanitizeFilename("Song: Remix") == "Song_ Remix")
        #expect(PathSanitizer.sanitizeFilename("AC/DC") == "AC_DC")
        #expect(PathSanitizer.sanitizeFilename("What?") == "What_")
        #expect(PathSanitizer.sanitizeFilename("file<>name") == "file__name")
        #expect(PathSanitizer.sanitizeFilename("a|b") == "a_b")
    }

    @Test func sanitizeEmptyAndWhitespace() {
        #expect(PathSanitizer.sanitizeFilename("") == "unknown")
        #expect(PathSanitizer.sanitizeFilename("   ") == "unknown")
        #expect(PathSanitizer.sanitizeFilename("  ") == "unknown")
    }

    @Test func sanitizeTrailingDots() {
        #expect(PathSanitizer.sanitizeFilename("song.") == "song")
        #expect(PathSanitizer.sanitizeFilename("song...") == "song")
    }

    @Test func sanitizeWindowsReservedNames() {
        // CON, PRN, AUX, NUL, COM1-9, LPT1-9 → prefixed with _
        #expect(PathSanitizer.sanitizeFilename("CON") == "_CON")
        #expect(PathSanitizer.sanitizeFilename("PRN") == "_PRN")
        #expect(PathSanitizer.sanitizeFilename("AUX") == "_AUX")
        #expect(PathSanitizer.sanitizeFilename("NUL") == "_NUL")
        #expect(PathSanitizer.sanitizeFilename("COM1") == "_COM1")
        #expect(PathSanitizer.sanitizeFilename("LPT3") == "_LPT3")
    }

    @Test func sanitizeWindowsReservedCaseInsensitive() {
        #expect(PathSanitizer.sanitizeFilename("con") == "_con")
        #expect(PathSanitizer.sanitizeFilename("Con") == "_Con")
    }

    @Test func sanitizeWindowsReservedWithExtension() {
        #expect(PathSanitizer.sanitizeFilename("CON.txt") == "_CON.txt")
    }

    @Test func sanitizeTruncatesLongNames() {
        let longName = String(repeating: "a", count: 300)
        let result = PathSanitizer.sanitizeFilename(longName)
        #expect(result.count == 255)
    }

    @Test func sanitizeTrimsWhitespace() {
        #expect(PathSanitizer.sanitizeFilename("  song  ") == "song")
    }

    // MARK: - Organized Path Tests

    @Test func organizedPathGeneration() {
        let metadata = TrackMetadata(
            artist: "artist name",
            albumArtist: "the beatles",
            album: "abbey road",
            title: "come together",
            genre: nil,
            year: nil,
            bitrate: nil,
            duration: nil,
            format: "mp3",
            originalPath: "/music/song.mp3"
        )

        let path = PathSanitizer.organizedPath(for: metadata)
        #expect(path == "the beatles/abbey road/come together.mp3")
    }

    @Test func organizedPathSanitizesComponents() {
        let metadata = TrackMetadata(
            artist: "artist",
            albumArtist: "AC/DC",
            album: "Back In Black: Deluxe",
            title: "Hells Bells",
            genre: nil,
            year: nil,
            bitrate: nil,
            duration: nil,
            format: "flac",
            originalPath: "/music/hells.flac"
        )

        let path = PathSanitizer.organizedPath(for: metadata)
        #expect(path == "AC_DC/Back In Black_ Deluxe/Hells Bells.flac")
    }

    @Test func organizedPathEmptyFieldsFallback() {
        let metadata = TrackMetadata(
            artist: "",
            albumArtist: "",
            album: "",
            title: "",
            genre: nil,
            year: nil,
            bitrate: nil,
            duration: nil,
            format: "mp3",
            originalPath: "/music/unknown.mp3"
        )

        let path = PathSanitizer.organizedPath(for: metadata)
        #expect(path == "unknown/unknown/unknown.mp3")
    }

    @Test func soundCloudPathGeneration() {
        let metadata = TrackMetadata(
            artist: "some producer",
            albumArtist: "some producer",
            album: "singles",
            title: "deep cut",
            genre: nil,
            year: nil,
            bitrate: nil,
            duration: nil,
            format: "mp3",
            originalPath: "/music/deep_cut.mp3"
        )

        let path = PathSanitizer.soundCloudPath(for: metadata)
        #expect(path == "SoundCloud/some producer/deep cut.mp3")
    }

    @Test func resolveFullPath() {
        let full = PathSanitizer.resolveFullPath(
            organizedPath: "artist/album/track.mp3",
            libraryRoot: "/Users/test/Music"
        )
        #expect(full.path == "/Users/test/Music/artist/album/track.mp3")
    }

    // MARK: - MetadataExtractor Format Detection

    @Test func isAudioFileDetectsSupported() {
        #expect(MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/music/song.mp3")))
        #expect(MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/music/song.MP3")))
        #expect(MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/music/song.flac")))
        #expect(MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/music/song.FLAC")))
        #expect(MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/music/song.m4a")))
        #expect(MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/music/song.aac")))
        #expect(MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/music/song.ogg")))
        #expect(MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/music/song.wav")))
        #expect(MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/music/song.aiff")))
        #expect(MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/music/song.alac")))
    }

    @Test func isAudioFileRejectsNonAudio() {
        #expect(!MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/docs/readme.txt")))
        #expect(!MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/images/photo.jpg")))
        #expect(!MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/data/file.json")))
        #expect(!MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/code/app.swift")))
        #expect(!MetadataExtractor.isAudioFile(URL(fileURLWithPath: "/video/clip.mp4")))
    }

    // MARK: - ImportService Scanner Tests

    @Test func scanDirectoryFindsAudioFiles() throws {
        // Create a temp directory with some audio files (empty, but correctly named)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_test_scan_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create fake audio files (scanner only checks extensions)
        let files = ["song1.mp3", "song2.flac", "song3.m4a"]
        for file in files {
            FileManager.default.createFile(
                atPath: tempDir.appendingPathComponent(file).path,
                contents: Data()
            )
        }

        // Create a non-audio file (should be skipped)
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("readme.txt").path,
            contents: Data()
        )

        let found = try ImportService.scanDirectory(tempDir)
        #expect(found.count == 3)
        #expect(found.allSatisfy { MetadataExtractor.isAudioFile($0) })
    }

    @Test func scanDirectoryRecurses() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_test_scan_recurse_\(UUID().uuidString)")
        let subDir = tempDir.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // File in root
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("root.mp3").path,
            contents: Data()
        )

        // File in subdirectory
        FileManager.default.createFile(
            atPath: subDir.appendingPathComponent("track.flac").path,
            contents: Data()
        )

        let found = try ImportService.scanDirectory(tempDir)
        #expect(found.count == 2)
    }

    @Test func scanDirectoryReturnsEmpty() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_test_scan_empty_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let found = try ImportService.scanDirectory(tempDir)
        #expect(found.isEmpty)
    }

    @Test func scanDirectoryIsSorted() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_test_scan_sort_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let files = ["charlie.mp3", "alpha.mp3", "bravo.mp3"]
        for file in files {
            FileManager.default.createFile(
                atPath: tempDir.appendingPathComponent(file).path,
                contents: Data()
            )
        }

        let found = try ImportService.scanDirectory(tempDir)
        #expect(found.count == 3)
        // Should be sorted alphabetically by path
        #expect(found[0].lastPathComponent == "alpha.mp3")
        #expect(found[1].lastPathComponent == "bravo.mp3")
        #expect(found[2].lastPathComponent == "charlie.mp3")
    }

    @Test func scanDirectoryThrowsForMissing() {
        let noSuchDir = URL(fileURLWithPath: "/tmp/definitely_does_not_exist_\(UUID().uuidString)")
        #expect(throws: ImportService.ImportError.self) {
            try ImportService.scanDirectory(noSuchDir)
        }
    }

    // MARK: - Array Chunking

    @Test func arrayChunking() {
        let arr = [1, 2, 3, 4, 5, 6, 7]
        let chunks = arr.chunked(into: 3)
        #expect(chunks.count == 3)
        #expect(chunks[0] == [1, 2, 3])
        #expect(chunks[1] == [4, 5, 6])
        #expect(chunks[2] == [7])
    }

    @Test func arrayChunkingExactDivision() {
        let arr = [1, 2, 3, 4, 5, 6]
        let chunks = arr.chunked(into: 3)
        #expect(chunks.count == 2)
        #expect(chunks[0] == [1, 2, 3])
        #expect(chunks[1] == [4, 5, 6])
    }

    @Test func arrayChunkingEmpty() {
        let arr: [Int] = []
        let chunks = arr.chunked(into: 5)
        #expect(chunks.isEmpty)
    }

    // MARK: - Database Integration

    @Test func importBatchInsertsTracksIntoDatabase() async throws {
        let db = try DatabaseManager.inMemory()

        // Insert tracks manually to simulate what ImportService does
        try db.write { db in
            var track = Track(
                artist: "test artist",
                albumArtist: "test artist",
                album: "test album",
                title: "test track",
                format: "mp3",
                originalPath: "/music/test.mp3"
            )
            track.organizedPath = "test artist/test album/test track.mp3"
            track.dateAdded = ISO8601DateFormatter().string(from: Date())
            try track.insert(db)
        }

        // Verify insertion
        let count = try db.read { db in
            try Track.fetchCount(db)
        }
        #expect(count == 1)

        // Verify organized path was set
        let track = try db.read { db in
            try Track.fetchOne(db)
        }
        #expect(track?.organizedPath == "test artist/test album/test track.mp3")
    }

    @Test func importSkipsDuplicateOriginalPaths() async throws {
        let db = try DatabaseManager.inMemory()

        try db.write { db in
            var track = Track(
                artist: "artist",
                album: "album",
                title: "track",
                format: "mp3",
                originalPath: "/music/song.mp3"
            )
            try track.insert(db)
        }

        // Try inserting the same original_path again
        let countBefore = try db.read { db in try Track.fetchCount(db) }

        // The duplicate should fail due to UNIQUE constraint on original_path
        let didThrow: Bool
        do {
            try db.write { db in
                var track = Track(
                    artist: "artist",
                    album: "album",
                    title: "track duplicate",
                    format: "mp3",
                    originalPath: "/music/song.mp3"
                )
                try track.insert(db)
            }
            didThrow = false
        } catch {
            didThrow = true
        }

        // Should have thrown due to UNIQUE constraint
        #expect(didThrow)

        let countAfter = try db.read { db in try Track.fetchCount(db) }
        #expect(countAfter == countBefore)
    }
}
