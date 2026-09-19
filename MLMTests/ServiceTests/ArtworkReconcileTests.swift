import Testing
import Foundation
@testable import MLM

@Suite("ArtworkReconcile — danglingTrackIds", .serialized)
struct ArtworkReconcileTests {

    /// Absolute path pointing to a file that EXISTS on disk → NOT dangling.
    @Test func testExistingFileIsNotDangling() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkReconcileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write a real JPEG (minimal valid content — just needs to exist on disk).
        let existingPath = tempDir.appendingPathComponent("42_1200.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: existingPath)

        let entries: [(trackId: Int64, artworkPath: String)] = [
            (42, existingPath.path)
        ]

        let dangling = ArtworkBackfillService.danglingTrackIds(from: entries)
        #expect(dangling.isEmpty, "Existing file must not be flagged as dangling")
    }

    /// Absolute path pointing to a file that does NOT exist → dangling.
    @Test func testMissingAbsoluteFileIsDangling() {
        let bogusPath = "/tmp/nonexistent_artwork_\(UUID().uuidString)/99_1200.jpg"
        let entries: [(trackId: Int64, artworkPath: String)] = [
            (99, bogusPath)
        ]

        let dangling = ArtworkBackfillService.danglingTrackIds(from: entries)
        #expect(dangling == [99], "Missing absolute path must be flagged as dangling")
    }

    /// Relative paths (e.g. legacy "artwork_cache/4_500.jpg") are always dangling —
    /// they never resolved to an absolute filesystem location.
    @Test func testRelativePathIsAlwaysDangling() {
        let entries: [(trackId: Int64, artworkPath: String)] = [
            (4, "artwork_cache/4_500.jpg")
        ]

        let dangling = ArtworkBackfillService.danglingTrackIds(from: entries)
        #expect(dangling == [4], "Relative path must always be flagged as dangling")
    }

    /// Mixed fixture: one existing file, one missing absolute, one relative.
    /// Exactly the dangling/relative ids are selected; the resolvable one is not.
    @Test func testMixedFixtureSelectsOnlyDangling() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtworkReconcileTests-mixed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let existingPath = tempDir.appendingPathComponent("10_1200.jpg")
        try Data([0xFF, 0xD8]).write(to: existingPath)

        let entries: [(trackId: Int64, artworkPath: String)] = [
            (10, existingPath.path),                              // exists → keep
            (20, "/tmp/gone_\(UUID().uuidString)/20_1200.jpg"),   // missing absolute → dangling
            (30, "artwork_cache/30_500.jpg"),                     // relative → dangling
        ]

        let dangling = ArtworkBackfillService.danglingTrackIds(from: entries)
        #expect(Set(dangling) == Set([20, 30]),
                "Only the missing-absolute and relative entries should be dangling")
        #expect(!dangling.contains(10),
                "The resolvable entry must NOT be flagged")
    }

    /// Empty input → empty output.
    @Test func testEmptyInputReturnsEmpty() {
        let entries: [(trackId: Int64, artworkPath: String)] = []
        let dangling = ArtworkBackfillService.danglingTrackIds(from: entries)
        #expect(dangling.isEmpty)
    }
}
