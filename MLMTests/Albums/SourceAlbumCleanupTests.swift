import Foundation
import GRDB
import Testing
@testable import MLM

/// `Clear Source Names from Album` (W4-3, IMP-085, ROADMAP C3): which names, the provenance,
/// the one undo step.
@Suite("SourceAlbumCleanupTests", .serialized)
@MainActor
struct SourceAlbumCleanupTests {
    typealias Env = AlbumSuggestionDecisionsTests.Env

    nonisolated static func track(_ db: Database, _ title: String, album: String, originalPath: String? = nil) throws -> Int64 {
        let id = try AlbumTracksMigrationTests.insertTrack(db, title: title, album: album)
        if let originalPath { try db.execute(sql: "UPDATE tracks SET original_path = ? WHERE id = ?", arguments: [originalPath, id]) }
        return id
    }

    static func run(_ env: Env) async throws -> SourceAlbumCleanup.Outcome? {
        let cleanup = SourceAlbumCleanup(database: env.db)
        let tracks = try await cleanup.affected()
        return try await cleanup.run(tracks: tracks, tagEdit: env.decisions.dependencies.tagEdit(), undo: env.undo,
                                     volumeName: { nil }, now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    static func albums(_ env: Env) async throws -> [String: String] {
        try await env.db.read { db in
            var result: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT title, album FROM tracks") { result[row["title"]] = row["album"] }
            return result
        }
    }

    // MARK: Names

    @Test func theKnownNamesMatchCaseInsensitivelyAndTrimmed() {
        for name in ["SoundCloud", "youtube", " Spotify ", "DAB", "qobuz", "LAST.FM", "SoundCloud Likes", "YouTube likes", "downloads"] {
            #expect(SourceAlbumNames.isSourceName(name), "\(name)")
        }
        for name in ["Good Lies", "Soundcloud Sessions", "", "YouTube Rewind 2019", "Downloads Vol. 2", "unknown album"] {
            #expect(!SourceAlbumNames.isSourceName(name), "\(name)")
        }
    }

    @Test func theSqlPredicateFindsExactlyThoseTracks() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            for (index, album) in ["SoundCloud", "youtube likes", " Qobuz ", "Good Lies", "Soundcloud Sessions", ""].enumerated() {
                _ = try Self.track(db, "T\(index)", album: album)
            }
        }
        let titles = try await db.read { db in try String.fetchAll(db, sql: "SELECT title FROM tracks WHERE \(SourceAlbumNames.sql) ORDER BY id") }
        #expect(titles == ["T0", "T1", "T2"])
        let count = try await db.read { db in try SourceAlbumCleanup.count(db) }
        #expect(count == 3)
        #expect(try await db.read { db in try MaintenanceCoverage.load(db) }.sourceNamedAlbums == 3)
    }

    @Test func theCoverageSentenceAndTheMenuItem() {
        var coverage = MaintenanceCoverage()
        coverage.sourceNamedAlbums = 12
        #expect(coverage.text(for: MaintenanceJob.clearSourceNames) == "12 tracks have a source name as album")
        coverage.sourceNamedAlbums = 1
        #expect(coverage.text(for: MaintenanceJob.clearSourceNames) == "1 track has a source name as album")
        let entry = MenuCommand.clearSourceNames.entry
        #expect(entry.title == "Clear Source Names from Album…")
        #expect(entry.parent == .maintenance)
        #expect(SourceAlbumCleanup.nothingToClear == "No track has a source name as album.")
        #expect(SourceAlbumCleanup.alertTitle(812) == "Clear the source name from \(812.formatted(.number)) tracks?")
        #expect(SourceAlbumCleanup.alertButton(812) == "Clear \(812.formatted(.number)) Albums")
        #expect(MaintenanceJob(action: MaintenanceJob.clearSourceNames).title == "Clear source names from Album")
    }

    // MARK: The step

    @Test func onlySourceNamedTracksAreBlankedInOneUndoStep() async throws {
        let env = try AlbumSuggestionDecisionsTests.env()
        try await env.db.write { db in
            _ = try Self.track(db, "A", album: "SoundCloud")
            _ = try Self.track(db, "B", album: "youtube likes")
            _ = try Self.track(db, "C", album: "Good Lies")
            _ = try Self.track(db, "D", album: "")
        }
        let outcome = try #require(try await Self.run(env))
        #expect(outcome.count == 2)
        let after = try await Self.albums(env)
        #expect(after == ["A": "", "B": "", "C": "Good Lies", "D": ""])
        #expect(env.manager.undoActionName == "Clear Source Names")
        #expect(env.status.message?.text == "Cleared the source name from 2 tracks")

        env.manager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await Self.albums(env) == ["A": "SoundCloud", "B": "youtube likes", "C": "Good Lies", "D": ""], "one step restores both")
        env.manager.redo()
        await env.undo.waitUntilIdle()
        #expect(try await Self.albums(env) == after)
    }

    @Test func nothingToClearIsNoStep() async throws {
        let env = try AlbumSuggestionDecisionsTests.env()
        try await env.db.write { db in _ = try Self.track(db, "C", album: "Good Lies") }
        let outcome = try await Self.run(env)
        #expect(outcome == nil)
        #expect(env.manager.undoActionName.isEmpty)
    }

    @Test func cleanupWritesTheFilesOnlyWhenTagWritingIsOn() async throws {
        let env = try AlbumSuggestionDecisionsTests.env(writesEnabled: true, reachable: false, volume: "Lexxar")
        try await env.db.write { db in
            let id = try Self.track(db, "A", album: "SoundCloud")
            try db.execute(sql: "UPDATE tracks SET organized_path = 'X/A.flac' WHERE id = ?", arguments: [id])
        }
        let cleanup = SourceAlbumCleanup(database: env.db)
        let tracks = try await cleanup.affected()
        _ = try await cleanup.run(tracks: tracks, tagEdit: env.decisions.dependencies.tagEdit(), undo: env.undo, volumeName: { "Lexxar" })
        let queued = try await env.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_tag_writes") }
        #expect(queued == 1)
        #expect(env.status.message?.text == "Cleared the source name from 1 track · 1 tag change waiting for “Lexxar”")
    }

    // MARK: Provenance

    @Test func aMissingTrackSourcesRowIsInsertedWhenTheSourceAndTheIDExist() async throws {
        let env = try AlbumSuggestionDecisionsTests.env()
        let (soundcloud, youtube, noID): (Int64, Int64, Int64) = try await env.db.write { db in
            try db.execute(sql: "INSERT INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'default', 1)")
            let sourceID = db.lastInsertedRowID
            let soundcloud = try Self.track(db, "A", album: "SoundCloud", originalPath: "soundcloud://12345")
            let youtube = try Self.track(db, "B", album: "YouTube", originalPath: "youtube://abc")
            let noID = try Self.track(db, "C", album: "soundcloud likes", originalPath: "/Users/me/Music/c.mp3")
            _ = sourceID
            return (soundcloud, youtube, noID)
        }
        _ = try await Self.run(env)
        let links = try await env.db.read { db in
            try Row.fetchAll(db, sql: "SELECT track_id, external_id FROM track_sources ORDER BY track_id").map { ($0["track_id"] as Int64, $0["external_id"] as String) }
        }
        #expect(links.count == 1 && links[0].0 == soundcloud && links[0].1 == "12345")
        let sourceRows = try await env.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sources") }
        #expect(sourceRows == 1, "a sources row is never created")
        let log = try await env.db.read { db in try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = ?", arguments: [SourceAlbumCleanup.logKey]) }
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(try #require(log).utf8))
        #expect(decoded == [String(youtube): "YouTube", String(noID): "soundcloud likes"], "no source row / no id → the log keeps the word")
    }

    @Test func aTrackAlreadyLinkedToASourceNeedsNeitherARowNorALogEntry() async throws {
        let env = try AlbumSuggestionDecisionsTests.env()
        try await env.db.write { db in
            try db.execute(sql: "INSERT INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'default', 1)")
            let sourceID = db.lastInsertedRowID
            let id = try Self.track(db, "A", album: "SoundCloud", originalPath: "soundcloud://1")
            try db.execute(sql: "INSERT INTO track_sources (track_id, source_id, external_id, added_at) VALUES (?, ?, '1', '2026-01-01')", arguments: [id, sourceID])
        }
        _ = try await Self.run(env)
        let log = try await env.db.read { db in try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = ?", arguments: [SourceAlbumCleanup.logKey]) }
        #expect(log == nil)
        let links = try await env.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_sources") }
        #expect(links == 1)
    }

    @Test func theLogIsMergedAndUndoRestoresItAndTheInsertedRows() async throws {
        let env = try AlbumSuggestionDecisionsTests.env()
        let (linked, logged): (Int64, Int64) = try await env.db.write { db in
            try db.execute(sql: "INSERT INTO sources (name, user_id, enabled) VALUES ('soundcloud', 'default', 1)")
            try db.execute(sql: "INSERT INTO app_config (key, value, updated_at) VALUES (?, '{\"99\":\"Downloads\"}', datetime('now'))", arguments: [SourceAlbumCleanup.logKey])
            return (try Self.track(db, "A", album: "SoundCloud", originalPath: "soundcloud://7"),
                    try Self.track(db, "B", album: "DAB", originalPath: "/x/b.flac"))
        }
        _ = try await Self.run(env)
        let merged = try await env.db.read { db in try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = ?", arguments: [SourceAlbumCleanup.logKey]) }
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(try #require(merged).utf8))
        #expect(decoded == ["99": "Downloads", String(logged): "DAB"], "an earlier log is kept")
        #expect(try await env.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_sources WHERE track_id = ?", arguments: [linked]) } == 1)

        env.manager.undo()
        await env.undo.waitUntilIdle()
        let restoredLog = try await env.db.read { db in try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = ?", arguments: [SourceAlbumCleanup.logKey]) }
        #expect(restoredLog == "{\"99\":\"Downloads\"}")
        let linksAfterUndo = try await env.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_sources") }
        #expect(linksAfterUndo == 0)
        env.manager.redo()
        await env.undo.waitUntilIdle()
        let linksAfterRedo = try await env.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_sources") }
        #expect(linksAfterRedo == 1)
    }

    @Test func externalIDsComeFromTheStoredPath() {
        #expect(SourceAlbumNames.externalID(originalPath: "soundcloud://123", source: "soundcloud") == "123")
        #expect(SourceAlbumNames.externalID(originalPath: "spotify:track:abc", source: "spotify") == "abc")
        #expect(SourceAlbumNames.externalID(originalPath: "youtube://xyz", source: "youtube") == "xyz")
        #expect(SourceAlbumNames.externalID(originalPath: "/a/b.mp3", source: "soundcloud") == nil)
        #expect(SourceAlbumNames.externalID(originalPath: "soundcloud://", source: "soundcloud") == nil)
        #expect(SourceAlbumNames.sourceName(forAlbum: "SoundCloud Likes") == "soundcloud")
        #expect(SourceAlbumNames.sourceName(forAlbum: "Downloads") == nil)
    }
}
