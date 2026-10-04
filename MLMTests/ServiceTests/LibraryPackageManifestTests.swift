import Testing
import Foundation
@testable import MLM

/// A3 Wave 1: `library.json` manifest (A0 D6) — schema, atomic write, tolerant read.
@Suite("LibraryPackageManifest (A3 Wave 1)")
struct LibraryPackageManifestTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryPackageManifestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var sample: LibraryPackageManifest {
        LibraryPackageManifest(
            libraryId: "f1c9d287-7c19-4e62-ad81-eef851bf751f",
            name: "Main Library",
            createdAt: Date(timeIntervalSince1970: 1_791_115_200), // 2026-10-04T12:00:00Z
            schemaVersion: "v41_remote_provider_identity"
        )
    }

    @Test func roundTripsThroughDisk() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent(LibraryPackageManifest.fileName)
        try sample.write(to: url)
        #expect(try LibraryPackageManifest.read(from: url) == sample)
    }

    @Test func usesSnakeCaseKeysAndISO8601Dates() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent(LibraryPackageManifest.fileName)
        try sample.write(to: url)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["manifest_version"] as? Int == 1)
        #expect(json["library_id"] as? String == "f1c9d287-7c19-4e62-ad81-eef851bf751f")
        #expect(json["name"] as? String == "Main Library")
        #expect(json["created_at"] as? String == "2026-10-04T12:00:00Z")
        #expect(json["schema_version"] as? String == "v41_remote_provider_identity")
    }

    @Test func readsTheA0Example() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent(LibraryPackageManifest.fileName)
        try Data("""
        {
          "manifest_version": 1,
          "library_id": "f1c9d287-7c19-4e62-ad81-eef851bf751f",
          "name": "Main Library",
          "created_at": "2026-10-04T12:00:00Z",
          "schema_version": "v41_remote_provider_identity",
          "future_field": true
        }
        """.utf8).write(to: url)
        #expect(try LibraryPackageManifest.read(from: url) == sample)
    }

    @Test func toleratesMissingSchemaVersion() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent(LibraryPackageManifest.fileName)
        try Data("""
        {"manifest_version": 1, "library_id": "abc", "name": "X", "created_at": "2026-10-04T12:00:00Z"}
        """.utf8).write(to: url)
        let manifest = try LibraryPackageManifest.read(from: url)
        #expect(manifest.schemaVersion == nil)
        #expect(manifest.libraryId == "abc")
    }

    @Test func rejectsNewerManifestVersion() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent(LibraryPackageManifest.fileName)
        try Data("""
        {"manifest_version": 2, "library_id": "abc", "name": "X", "created_at": "2026-10-04T12:00:00Z"}
        """.utf8).write(to: url)
        #expect(throws: LibraryPackageManifest.ReadError.unsupportedVersion(2)) {
            try LibraryPackageManifest.read(from: url)
        }
    }

    @Test func reportsMissingFile() throws {
        let dir = try makeTempDir()
        #expect(throws: LibraryPackageManifest.ReadError.missing) {
            try LibraryPackageManifest.read(from: dir.appendingPathComponent(LibraryPackageManifest.fileName))
        }
    }

    @Test func reportsMalformedFile() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent(LibraryPackageManifest.fileName)
        try Data("{ not json".utf8).write(to: url)
        #expect(throws: LibraryPackageManifest.ReadError.malformed) {
            try LibraryPackageManifest.read(from: url)
        }
    }

    @Test func rejectsEmptyLibraryId() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent(LibraryPackageManifest.fileName)
        try Data("""
        {"manifest_version": 1, "library_id": "", "name": "X", "created_at": "2026-10-04T12:00:00Z"}
        """.utf8).write(to: url)
        #expect(throws: LibraryPackageManifest.ReadError.malformed) {
            try LibraryPackageManifest.read(from: url)
        }
    }

    @Test func overwriteReplacesPreviousContent() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent(LibraryPackageManifest.fileName)
        try sample.write(to: url)
        var renamed = sample
        renamed.name = "Renamed"
        try renamed.write(to: url)
        #expect(try LibraryPackageManifest.read(from: url).name == "Renamed")
    }

    @Test func failedWriteLeavesNoPartialFile() throws {
        let dir = try makeTempDir()
        // A directory where the file should go makes the final rename fail.
        let url = dir.appendingPathComponent(LibraryPackageManifest.fileName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try sample.write(to: url) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == [LibraryPackageManifest.fileName])
    }

    @Test func failedOverwriteKeepsPreviousFile() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent(LibraryPackageManifest.fileName)
        try sample.write(to: url)
        // Make the directory read-only so the temp file can't be created.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        var renamed = sample
        renamed.name = "Renamed"
        #expect(throws: (any Error).self) { try renamed.write(to: url) }
        #expect(try LibraryPackageManifest.read(from: url) == sample)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [LibraryPackageManifest.fileName])
    }
}
