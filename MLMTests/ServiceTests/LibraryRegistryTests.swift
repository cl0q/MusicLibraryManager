import Testing
import Foundation
@testable import MLM

/// A3 Wave 1: `libraries.json` registry (A0 D5) — schema, atomic store, entry states,
/// scan rebuild and corrupt-file handling (Step-0 decision 10). Temp directories only.
@Suite("LibraryRegistry (A3 Wave 1)", .serialized)
struct LibraryRegistryTests {

    private let fixedNow = Date(timeIntervalSince1970: 1_791_115_200) // 2026-10-04T12:00:00Z

    private struct Fixture {
        let root: URL
        let store: LibraryRegistryStore

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LibraryRegistryTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = LibraryRegistryStore(
                fileURL: root.appendingPathComponent("libraries.json"),
                librariesDirectory: root.appendingPathComponent("libraries"))
        }

        var rootContents: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        }

        /// A directory with just a manifest — enough for the scan, which never opens SQLite.
        @discardableResult
        func makePackage(_ fileName: String, id: String, name: String) throws -> URL {
            let package = store.librariesDirectory.appendingPathComponent(fileName)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try LibraryPackageManifest(
                libraryId: id, name: name,
                createdAt: Date(timeIntervalSince1970: 0), schemaVersion: nil
            ).write(to: LibraryPackage.manifestURL(in: package))
            return package
        }
    }

    // MARK: - Model

    @Test func newRegistryRemembersLastLibraryByDefault() {
        let registry = LibraryRegistry()
        #expect(registry.registryVersion == 1)
        #expect(registry.libraries.isEmpty)
        #expect(registry.lastActiveLibraryId == nil)
        #expect(registry.rememberLastLibrary)
    }

    @Test func upsertAddsThenRepointsById() {
        var registry = LibraryRegistry()
        registry.upsert(libraryId: "a", url: URL(fileURLWithPath: "/x/Main Library.mlibm"), name: "Main Library")
        registry.upsert(libraryId: "a", url: URL(fileURLWithPath: "/Volumes/Disk/Main Library.mlibm"), name: "Main")
        #expect(registry.libraries.count == 1)
        #expect(registry.entry(withId: "a")?.url.path == "/Volumes/Disk/Main Library.mlibm")
        #expect(registry.entry(withId: "a")?.name == "Main")
    }

    @Test func upsertKeepsOneEntryPerPath() {
        var registry = LibraryRegistry()
        let url = URL(fileURLWithPath: "/x/Main Library.mlibm")
        registry.upsert(libraryId: "old", url: url, name: "Old")
        registry.lastActiveLibraryId = "old"
        registry.upsert(libraryId: "new", url: URL(fileURLWithPath: "/x/Main Library.mlibm/"), name: "New")
        #expect(registry.libraries.map(\.libraryId) == ["new"])
        #expect(registry.lastActiveLibraryId == nil)
    }

    @Test func entryURLHasNoTrailingSlashForExistingDirectories() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryRegistryTests-\(UUID().uuidString)/A.mlibm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var registry = LibraryRegistry()
        registry.upsert(libraryId: "a", url: dir, name: "A")
        #expect(registry.libraries[0].url == URL(filePath: dir.path, directoryHint: .notDirectory))
        #expect(!registry.libraries[0].url.absoluteString.hasSuffix("/"))
    }

    @Test func markOpenedSetsLastActiveAndTimestamp() {
        var registry = LibraryRegistry()
        registry.upsert(libraryId: "a", url: URL(fileURLWithPath: "/x/A.mlibm"), name: "A")
        registry.upsert(libraryId: "b", url: URL(fileURLWithPath: "/x/B.mlibm"), name: "B")
        registry.markOpened(libraryId: "b", at: fixedNow)
        #expect(registry.lastActiveLibraryId == "b")
        #expect(registry.lastActiveEntry?.name == "B")
        #expect(registry.entry(withId: "b")?.lastOpenedAt == fixedNow)
        #expect(registry.entry(withId: "a")?.lastOpenedAt == nil)
    }

    @Test func recentEntriesAreMostRecentlyOpenedFirst() {
        var registry = LibraryRegistry()
        for id in ["a", "b", "c"] {
            registry.upsert(libraryId: id, url: URL(fileURLWithPath: "/x/\(id).mlibm"), name: id)
        }
        registry.markOpened(libraryId: "a", at: fixedNow)
        registry.markOpened(libraryId: "c", at: fixedNow.addingTimeInterval(60))
        #expect(registry.recentEntries.map(\.libraryId) == ["c", "a", "b"])
    }

    @Test func entryLookupByPathIgnoresTrailingSlash() {
        var registry = LibraryRegistry()
        registry.upsert(libraryId: "a", url: URL(fileURLWithPath: "/x/A.mlibm"), name: "A")
        #expect(registry.entry(at: URL(fileURLWithPath: "/x/A.mlibm/"))?.libraryId == "a")
        #expect(registry.entry(at: URL(fileURLWithPath: "/x/B.mlibm")) == nil)
    }

    @Test func pathsUnderHomeAreStoredWithTilde() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var registry = LibraryRegistry()
        registry.upsert(libraryId: "a", url: URL(fileURLWithPath: "\(home)/Lib/A.mlibm"), name: "A")
        #expect(registry.libraries[0].path == "~/Lib/A.mlibm")
        #expect(registry.libraries[0].url.path == "\(home)/Lib/A.mlibm")
    }

    // MARK: - Availability

    @Test func availabilityDistinguishesNotFoundFromNotConnected() {
        let existing: Set<String> = ["/Users/o/A.mlibm", "/Volumes/Disk", "/Volumes/Disk/B.mlibm"]
        let exists: (String) -> Bool = { existing.contains($0) }
        #expect(LibraryRegistry.availability(of: URL(fileURLWithPath: "/Users/o/A.mlibm"), fileExists: exists) == .available)
        #expect(LibraryRegistry.availability(of: URL(fileURLWithPath: "/Users/o/Gone.mlibm"), fileExists: exists) == .notFound)
        #expect(LibraryRegistry.availability(of: URL(fileURLWithPath: "/Volumes/Disk/B.mlibm"), fileExists: exists) == .available)
        // Volume mounted, file gone → not found.
        #expect(LibraryRegistry.availability(of: URL(fileURLWithPath: "/Volumes/Disk/Gone.mlibm"), fileExists: exists) == .notFound)
        // Volume not mounted → not connected.
        #expect(LibraryRegistry.availability(of: URL(fileURLWithPath: "/Volumes/Other/C.mlibm"), fileExists: exists) == .notConnected)
    }

    // MARK: - Store

    @Test func saveAndLoadRoundTrip() throws {
        let f = try Fixture()
        var registry = LibraryRegistry()
        registry.upsert(libraryId: "a", url: URL(fileURLWithPath: "/x/A.mlibm"), name: "A")
        registry.markOpened(libraryId: "a", at: fixedNow)
        registry.rememberLastLibrary = false
        try f.store.save(registry)

        let loaded = try f.store.load()
        #expect(loaded.registry == registry)
        #expect(loaded.outcome == .loaded)
    }

    @Test func savedFileUsesA0Schema() throws {
        let f = try Fixture()
        var registry = LibraryRegistry()
        registry.upsert(libraryId: "a", url: URL(fileURLWithPath: "/x/A.mlibm"), name: "A")
        registry.markOpened(libraryId: "a", at: fixedNow)
        try f.store.save(registry)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: f.store.fileURL)) as? [String: Any])
        #expect(json["registry_version"] as? Int == 1)
        #expect(json["last_active_library_id"] as? String == "a")
        #expect(json["remember_last_library"] as? Bool == true)
        let entry = try #require((json["libraries"] as? [[String: Any]])?.first)
        #expect(entry["library_id"] as? String == "a")
        #expect(entry["path"] as? String == "/x/A.mlibm")
        #expect(entry["name"] as? String == "A")
        #expect(entry["last_opened_at"] as? String == "2026-10-04T12:00:00Z")
    }

    @Test func loadsTheA0Example() throws {
        let f = try Fixture()
        try Data("""
        {
          "registry_version": 1,
          "libraries": [
            {
              "library_id": "f1c9d287-7c19-4e62-ad81-eef851bf751f",
              "path": "~/Library/Application Support/com.musiclibrary.app/libraries/Main Library.mlibm",
              "name": "Main Library",
              "last_opened_at": "2026-10-04T12:00:00Z"
            }
          ],
          "last_active_library_id": "f1c9d287-7c19-4e62-ad81-eef851bf751f",
          "remember_last_library": true
        }
        """.utf8).write(to: f.store.fileURL)
        let loaded = try f.store.load()
        #expect(loaded.outcome == .loaded)
        let entry = try #require(loaded.registry.lastActiveEntry)
        #expect(entry.name == "Main Library")
        #expect(entry.url.path.hasSuffix("/Library/Application Support/com.musiclibrary.app/libraries/Main Library.mlibm"))
        #expect(!entry.url.path.hasPrefix("~"))
    }

    @Test func saveFailureKeepsPreviousFile() throws {
        let f = try Fixture()
        var registry = LibraryRegistry()
        registry.upsert(libraryId: "a", url: URL(fileURLWithPath: "/x/A.mlibm"), name: "A")
        try f.store.save(registry)
        let before = try Data(contentsOf: f.store.fileURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path) }
        registry.upsert(libraryId: "b", url: URL(fileURLWithPath: "/x/B.mlibm"), name: "B")
        #expect(throws: (any Error).self) { try f.store.save(registry) }
        #expect(try Data(contentsOf: f.store.fileURL) == before)
        #expect(f.rootContents == ["libraries.json"])
    }

    @Test func missingRegistryWithoutLibrariesIsEmptyAndWritesNothing() throws {
        let f = try Fixture()
        let loaded = try f.store.load()
        #expect(loaded.registry == LibraryRegistry())
        #expect(loaded.outcome == .rebuiltMissing)
        #expect(f.rootContents.isEmpty)
    }

    @Test func missingRegistryIsRebuiltByScan() throws {
        let f = try Fixture()
        try f.makePackage("Main Library.mlibm", id: "a", name: "Main Library")
        try f.makePackage("Dev.mlibm", id: "b", name: "Dev")
        // Not library files: no manifest, wrong extension, staging leftovers.
        try FileManager.default.createDirectory(
            at: f.store.librariesDirectory.appendingPathComponent("Broken.mlibm"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: f.store.librariesDirectory.appendingPathComponent("Other"), withIntermediateDirectories: true)
        try f.makePackage("Half.mlibm.partial", id: "c", name: "Half")

        let loaded = try f.store.load()
        #expect(loaded.outcome == .rebuiltMissing)
        #expect(loaded.registry.libraries.map(\.libraryId) == ["b", "a"]) // sorted by file name
        #expect(loaded.registry.entry(withId: "a")?.name == "Main Library")
        #expect(loaded.registry.lastActiveLibraryId == nil) // two candidates — the user picks
        // The rebuilt registry is persisted.
        #expect(try f.store.load().outcome == .loaded)
    }

    @Test func rebuildWithSingleLibraryMakesItActive() throws {
        let f = try Fixture()
        try f.makePackage("Main Library.mlibm", id: "a", name: "Main Library")
        let loaded = try f.store.load()
        #expect(loaded.registry.lastActiveLibraryId == "a")
    }

    @Test func rebuildSkipsDuplicateLibraryIds() throws {
        let f = try Fixture()
        try f.makePackage("Main Library.mlibm", id: "a", name: "Main Library")
        try f.makePackage("Main Library copy.mlibm", id: "a", name: "Main Library")
        let loaded = try f.store.load()
        #expect(loaded.registry.libraries.count == 1)
        #expect(loaded.registry.libraries[0].url.lastPathComponent == "Main Library copy.mlibm")
    }

    @Test func corruptRegistryIsPreservedAndRebuilt() throws {
        let f = try Fixture()
        try f.makePackage("Main Library.mlibm", id: "a", name: "Main Library")
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: f.store.fileURL)

        let loaded = try f.store.load(now: fixedNow)
        guard case .rebuiltCorrupt(let preserved) = loaded.outcome else {
            Issue.record("expected rebuiltCorrupt, got \(loaded.outcome)")
            return
        }
        #expect(preserved.lastPathComponent == "libraries.json.corrupt-20261004T120000Z")
        #expect(try Data(contentsOf: preserved) == garbage)
        #expect(loaded.registry.entry(withId: "a") != nil)
        #expect(try f.store.load().outcome == .loaded)
    }

    @Test func corruptRegistryNeverOverwritesAnEarlierCorruptCopy() throws {
        let f = try Fixture()
        try Data("first".utf8).write(to: f.store.fileURL)
        _ = try f.store.load(now: fixedNow)
        try Data("second".utf8).write(to: f.store.fileURL)
        _ = try f.store.load(now: fixedNow)
        let corrupt = f.rootContents.filter { $0.hasPrefix("libraries.json.corrupt-") }
        #expect(corrupt.count == 2)
    }

    @Test func newerRegistryVersionIsLeftUntouched() throws {
        let f = try Fixture()
        let newer = Data("""
        {"registry_version": 7, "libraries": [], "remember_last_library": true}
        """.utf8)
        try newer.write(to: f.store.fileURL)
        #expect(throws: LibraryRegistryStore.LoadError.unsupportedVersion(7)) {
            try f.store.load()
        }
        #expect(try Data(contentsOf: f.store.fileURL) == newer)
    }

    @Test func productionDefaultsLiveInApplicationSupport() {
        #expect(LibraryRegistryStore.defaultFileURL.path.hasSuffix(
            "Library/Application Support/com.musiclibrary.app/libraries.json"))
        #expect(LibraryRegistryStore.defaultLibrariesDirectory.path.hasSuffix(
            "Library/Application Support/com.musiclibrary.app/libraries"))
    }
}
