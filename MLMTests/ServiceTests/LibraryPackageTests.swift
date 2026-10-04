import Testing
import Foundation
import GRDB
@testable import MLM

/// A3 Wave 1: `.mlibm` library file layout, creation, validation and manifest repair
/// (A0 D1, D5, D6, legacy migration guide step 3). Temp directories only.
@Suite("LibraryPackage (A3 Wave 1)", .serialized)
struct LibraryPackageTests {

    private let fixedNow = Date(timeIntervalSince1970: 1_791_115_200) // 2026-10-04T12:00:00Z

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryPackageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A hand-made library file: directory + migrated database, optionally with a library_id.
    private func makeManualPackage(in dir: URL, name: String, libraryId: String?) throws -> URL {
        let package = dir.appendingPathComponent("\(name).mlibm")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manager = try DatabaseManager(path: LibraryPackage.databaseURL(in: package))
        if let libraryId {
            try manager.pool.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO app_config (key, value) VALUES ('library_id', ?)",
                    arguments: [libraryId])
            }
        }
        return package
    }

    // MARK: - Layout

    @Test func layoutMatchesA0() {
        let package = URL(fileURLWithPath: "/tmp/Main Library.mlibm")
        #expect(LibraryPackage.fileExtension == "mlibm")
        #expect(LibraryPackage.manifestURL(in: package).lastPathComponent == "library.json")
        #expect(LibraryPackage.databaseURL(in: package).lastPathComponent == "music_library.db")
        #expect(LibraryPackage.coversDirectory(in: package).lastPathComponent == "playlist-covers")
        // Covers stay next to the DB, so DatabaseManager's rule and the package agree.
        #expect(DatabaseManager.playlistCoversDirectory(forDatabaseAt: LibraryPackage.databaseURL(in: package))
                == LibraryPackage.coversDirectory(in: package))
    }

    // MARK: - File names

    @Test func fileNameKeepsReadableNames() {
        #expect(LibraryPackage.fileName(forLibraryName: "Main Library") == "Main Library.mlibm")
        #expect(LibraryPackage.fileName(forLibraryName: "Über Bässe") == "Über Bässe.mlibm")
    }

    @Test func fileNameSanitizesUnsafeCharacters() {
        #expect(LibraryPackage.fileName(forLibraryName: "Rock/Pop: Live") == "Rock-Pop- Live.mlibm")
        #expect(LibraryPackage.fileName(forLibraryName: "  .hidden  ") == "hidden.mlibm")
        #expect(LibraryPackage.fileName(forLibraryName: "   ") == "Library.mlibm")
        #expect(LibraryPackage.fileName(forLibraryName: "a\u{0}b\nc") == "abc.mlibm")
    }

    @Test func fileNameIsLengthLimited() {
        let long = String(repeating: "x", count: 400)
        let name = LibraryPackage.fileName(forLibraryName: long)
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(".mlibm"))
    }

    @Test func availableURLAvoidsExistingFiles() throws {
        let dir = try makeTempDir()
        let first = LibraryPackage.availablePackageURL(forLibraryName: "Main Library", in: dir)
        #expect(first.lastPathComponent == "Main Library.mlibm")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        let partial = dir.appendingPathComponent("Main Library 2.mlibm.partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
        let next = LibraryPackage.availablePackageURL(forLibraryName: "Main Library", in: dir)
        #expect(next.lastPathComponent == "Main Library 3.mlibm")
    }

    // MARK: - Create

    @Test func createEmptyBuildsACompleteLibraryFile() throws {
        let dir = try makeTempDir()
        let id = UUID().uuidString.lowercased()
        let package = try LibraryPackage.createEmpty(named: "Main Library", libraryId: id, in: dir, now: fixedNow)

        #expect(package.lastPathComponent == "Main Library.mlibm")
        let manifest = try LibraryPackageManifest.read(from: LibraryPackage.manifestURL(in: package))
        #expect(manifest.libraryId == id)
        #expect(manifest.name == "Main Library")
        #expect(manifest.createdAt == fixedNow)
        #expect(manifest.schemaVersion == DatabaseManager.buildMigrator().migrations.last)
        #expect(try LibraryPackage.readDatabaseLibraryId(at: LibraryPackage.databaseURL(in: package)) == id)
        // No staging directory left behind.
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == ["Main Library.mlibm"])
    }

    @Test func createEmptyNeverOverwritesAnExistingLibraryFile() throws {
        let dir = try makeTempDir()
        let first = try LibraryPackage.createEmpty(named: "Main Library", libraryId: "a", in: dir, now: fixedNow)
        let second = try LibraryPackage.createEmpty(named: "Main Library", libraryId: "b", in: dir, now: fixedNow)
        #expect(first != second)
        #expect(second.lastPathComponent == "Main Library 2.mlibm")
        #expect(try LibraryPackageManifest.read(from: LibraryPackage.manifestURL(in: first)).libraryId == "a")
    }

    // MARK: - Validate

    @Test func validateAcceptsAConsistentLibraryFile() throws {
        let dir = try makeTempDir()
        let package = try LibraryPackage.createEmpty(named: "Main Library", libraryId: "id-1", in: dir, now: fixedNow)
        let result = try LibraryPackage.validate(at: package, expectedLibraryId: "id-1", now: fixedNow)
        #expect(result.manifest.libraryId == "id-1")
        #expect(result.manifestRepaired == false)
    }

    @Test func validateReportsMissingPackage() throws {
        let dir = try makeTempDir()
        #expect(throws: LibraryPackage.ValidationError.notFound) {
            try LibraryPackage.validate(at: dir.appendingPathComponent("Gone.mlibm"), expectedLibraryId: nil, now: fixedNow)
        }
    }

    @Test func validateRejectsAPlainFile() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("Fake.mlibm")
        try Data("x".utf8).write(to: file)
        #expect(throws: LibraryPackage.ValidationError.missingDatabase) {
            try LibraryPackage.validate(at: file, expectedLibraryId: nil, now: fixedNow)
        }
    }

    @Test func validateRejectsPackageWithoutDatabase() throws {
        let dir = try makeTempDir()
        let package = dir.appendingPathComponent("Empty.mlibm")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        #expect(throws: LibraryPackage.ValidationError.missingDatabase) {
            try LibraryPackage.validate(at: package, expectedLibraryId: nil, now: fixedNow)
        }
    }

    @Test func validateReportsDatabaseWithoutLibraryId() throws {
        let dir = try makeTempDir()
        let package = try makeManualPackage(in: dir, name: "Manual", libraryId: nil)
        #expect(throws: LibraryPackage.ValidationError.missingLibraryId) {
            try LibraryPackage.validate(at: package, expectedLibraryId: nil, now: fixedNow)
        }
        // Nothing was written: no manifest invented without an id.
        #expect(!FileManager.default.fileExists(atPath: LibraryPackage.manifestURL(in: package).path))
    }

    @Test func validateRepairsMissingManifestFromDatabase() throws {
        let dir = try makeTempDir()
        let package = try makeManualPackage(in: dir, name: "Moved Library", libraryId: "db-id")
        let result = try LibraryPackage.validate(at: package, expectedLibraryId: nil, now: fixedNow)

        #expect(result.manifestRepaired)
        #expect(result.manifest.libraryId == "db-id")
        #expect(result.manifest.name == "Moved Library")
        #expect(result.manifest.createdAt == fixedNow)
        #expect(result.manifest.schemaVersion == DatabaseManager.buildMigrator().migrations.last)
        #expect(try LibraryPackageManifest.read(from: LibraryPackage.manifestURL(in: package)) == result.manifest)
    }

    @Test func validateRepairsMalformedManifestFromDatabase() throws {
        let dir = try makeTempDir()
        let package = try makeManualPackage(in: dir, name: "Broken", libraryId: "db-id")
        try Data("{ nope".utf8).write(to: LibraryPackage.manifestURL(in: package))
        let result = try LibraryPackage.validate(at: package, expectedLibraryId: nil, now: fixedNow)
        #expect(result.manifestRepaired)
        #expect(result.manifest.libraryId == "db-id")
    }

    @Test func validateNeverOverwritesANewerManifest() throws {
        let dir = try makeTempDir()
        let package = try makeManualPackage(in: dir, name: "Future", libraryId: "db-id")
        let newer = Data("""
        {"manifest_version": 9, "library_id": "db-id", "name": "Future", "created_at": "2026-10-04T12:00:00Z"}
        """.utf8)
        try newer.write(to: LibraryPackage.manifestURL(in: package))
        #expect(throws: LibraryPackage.ValidationError.unsupportedManifestVersion(9)) {
            try LibraryPackage.validate(at: package, expectedLibraryId: nil, now: fixedNow)
        }
        #expect(try Data(contentsOf: LibraryPackage.manifestURL(in: package)) == newer)
    }

    @Test func validateDetectsManifestDatabaseMismatch() throws {
        let dir = try makeTempDir()
        let package = try LibraryPackage.createEmpty(named: "A", libraryId: "manifest-id", in: dir, now: fixedNow)
        let dbURL = LibraryPackage.databaseURL(in: package)
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: "UPDATE app_config SET value = 'other-id' WHERE key = 'library_id'")
        }
        try queue.close()
        let manifestBefore = try Data(contentsOf: LibraryPackage.manifestURL(in: package))

        #expect(throws: LibraryPackage.ValidationError.idMismatch(expected: "manifest-id", found: "other-id")) {
            try LibraryPackage.validate(at: package, expectedLibraryId: nil, now: fixedNow)
        }
        // A mismatch is never silently repaired.
        #expect(try Data(contentsOf: LibraryPackage.manifestURL(in: package)) == manifestBefore)
    }

    @Test func validateDetectsRegistryMismatch() throws {
        let dir = try makeTempDir()
        let package = try LibraryPackage.createEmpty(named: "A", libraryId: "real-id", in: dir, now: fixedNow)
        #expect(throws: LibraryPackage.ValidationError.idMismatch(expected: "registry-id", found: "real-id")) {
            try LibraryPackage.validate(at: package, expectedLibraryId: "registry-id", now: fixedNow)
        }
    }

    @Test func reassignGivesACopyItsOwnIdentity() throws {
        let dir = try makeTempDir()
        let package = try LibraryPackage.createEmpty(named: "Copy", libraryId: "old", in: dir, now: fixedNow)
        try LibraryPackage.reassignLibraryId("new", in: package, now: fixedNow.addingTimeInterval(60))
        #expect(try LibraryPackage.readDatabaseLibraryId(at: LibraryPackage.databaseURL(in: package)) == "new")
        let manifest = try LibraryPackageManifest.read(from: LibraryPackage.manifestURL(in: package))
        #expect(manifest.libraryId == "new")
        #expect(manifest.name == "Copy")
        #expect(manifest.createdAt == fixedNow.addingTimeInterval(60))
        #expect(try LibraryPackage.validate(at: package, expectedLibraryId: "new", now: fixedNow).manifestRepaired == false)
    }

    @Test func readDatabaseLibraryIdDoesNotCreateMissingDatabase() throws {
        let dir = try makeTempDir()
        let dbURL = dir.appendingPathComponent("music_library.db")
        #expect(try LibraryPackage.readDatabaseLibraryId(at: dbURL) == nil)
        #expect(!FileManager.default.fileExists(atPath: dbURL.path))
    }
}
