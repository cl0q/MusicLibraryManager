import Foundation
import GRDB
import Testing
@testable import MLM

/// `v52_album_suggestions` and `AlbumSuggestionRepository` (W4-3, IMP-082/083/084). Temporary
/// databases only; foreign keys off.
@Suite("AlbumSuggestionRepositoryTests")
struct AlbumSuggestionRepositoryTests {
    static let v52 = "v52_album_suggestions"
    static let previous = "v51_album_dedup"

    static func suggestion(_ title: String, match: Double = 80, source: String = "Folder name",
                           artist: String = "", year: Int? = nil, number: Int? = nil) -> AlbumSuggestion {
        AlbumSuggestion(albumTitle: title, albumArtist: artist, year: year, trackNumber: number, disc: nil, source: source, match: match)
    }

    static func row(_ trackID: Int64, _ title: String, match: Double = 80, status: AlbumSuggestionStatus = .pending,
                    alternatives: [AlbumSuggestion] = []) -> AlbumSuggestionRow {
        AlbumSuggestionRow(trackID: trackID, suggestion: suggestion(title, match: match), alternatives: alternatives,
                           status: status, decidedAt: nil)
    }

    static func track(_ db: Database, _ title: String, artist: String = "Overmono", album: String = "") throws -> Int64 {
        try AlbumTracksMigrationTests.insertTrack(db, title: title, artist: artist, album: album)
    }

    // MARK: Migration

    @Test func freshDatabaseHasTheTableAndTheColumn() throws {
        let queue = try DatabaseManager.inMemory()
        let (suggestionColumns, trackColumns, trackIndexes) = try queue.read { db in
            (try db.columns(in: "album_suggestions").map(\.name), try db.columns(in: "tracks").map(\.name),
             try db.indexes(on: "tracks").map(\.name))
        }
        #expect(suggestionColumns == [
            "track_id", "album_title", "album_artist", "year", "track_number", "disc",
            "source", "match", "alternatives_json", "status", "decided_at",
        ])
        #expect(trackColumns.contains("no_album"))
        #expect(trackIndexes.contains("idx_tracks_no_album"))
    }

    @Test func registeredOnceAfterV51() throws {
        let migrations = DatabaseManager.buildMigrator().migrations
        #expect(migrations.filter { $0 == Self.v52 }.count == 1)
        let before = try #require(migrations.firstIndex(of: Self.previous))
        let at = try #require(migrations.firstIndex(of: Self.v52))
        #expect(before < at)
    }

    @Test func migratesAV51DatabaseWithoutTouchingItsRows() throws {
        let queue = try DatabaseQueue(configuration: AlbumTracksMigrationTests.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.previous)
        let id = try queue.write { db in try Self.track(db, "Kept", album: "") }
        try migrator.migrate(queue)
        let (flag, rows) = try queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT no_album FROM tracks WHERE id = ?", arguments: [id]),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_suggestions"))
        }
        #expect(flag == 0)
        #expect(rows == 0, "no backfill")
    }

    @Test func theMigrationBodyIsIdempotent() throws {
        let queue = try DatabaseManager.inMemory()
        try queue.write { db in try AlbumSuggestionMigration.v52(db) }
        let exists = try queue.read { db in try db.tableExists("album_suggestions") }
        #expect(exists)
    }

    // MARK: Rows

    @Test func aRowRoundTripsWithItsAlternatives() async throws {
        let queue = try DatabaseManager.inMemory()
        let id = try await queue.write { db in try Self.track(db, "Song") }
        let repo = AlbumSuggestionRepository(database: queue)
        let alternatives = [Self.suggestion("B", match: 60, source: "Library tags", year: 2020), Self.suggestion("C", match: 50)]
        try await repo.upsert([Self.row(id, "A", match: 88, alternatives: alternatives)])
        let loaded = try #require(try await repo.row(trackID: id))
        #expect(loaded.suggestion.albumTitle == "A")
        #expect(loaded.alternatives == alternatives)
        #expect(loaded.status == .pending)
    }

    @Test func lookedUpRowsKeepTheBestAndFileTheRest() {
        let row = AlbumSuggestionRow.looked(up: 7, candidates: [Self.suggestion("Low", match: 40), Self.suggestion("High", match: 90), Self.suggestion("Mid", match: 70)])
        #expect(row.suggestion.albumTitle == "High")
        #expect(row.alternatives.map(\.albumTitle) == ["Mid", "Low"])
        let none = AlbumSuggestionRow.looked(up: 8, candidates: [])
        #expect(none.status == .noMatch && !none.hasSuggestion && none.suggestion.match == 0)
    }

    @Test func choosingAnAlternativeSwapsItWithTheSuggestion() async throws {
        let queue = try DatabaseManager.inMemory()
        let id = try await queue.write { db in try Self.track(db, "Song") }
        let repo = AlbumSuggestionRepository(database: queue)
        try await repo.upsert([Self.row(id, "A", match: 88, alternatives: [Self.suggestion("B", match: 60)])])
        let chosen = try #require(try await repo.choose(alternativeAt: 0, trackID: id))
        #expect(chosen.suggestion.albumTitle == "B")
        #expect(chosen.alternatives.map(\.albumTitle) == ["A"])
        #expect(try await repo.choose(alternativeAt: 5, trackID: id) == nil)
    }

    // MARK: Lists and counts

    @Test func pendingListsBestFirstAndOnlyTracksStillWithoutAlbum() async throws {
        let queue = try DatabaseManager.inMemory()
        let (a, b, gone, hidden, decided): (Int64, Int64, Int64, Int64, Int64) = try await queue.write { db in
            let a = try Self.track(db, "A")
            let b = try Self.track(db, "B")
            let gone = try Self.track(db, "Got an album since")
            let hidden = try Self.track(db, "Hidden")
            let decided = try Self.track(db, "Rejected")
            try db.execute(sql: "UPDATE tracks SET hidden_by_review = 1 WHERE id = ?", arguments: [hidden])
            return (a, b, gone, hidden, decided)
        }
        let repo = AlbumSuggestionRepository(database: queue)
        try await repo.upsert([Self.row(a, "Low", match: 60), Self.row(b, "High", match: 95), Self.row(gone, "X"),
                               Self.row(hidden, "Y"), Self.row(decided, "Z", status: .rejected)])
        try await queue.write { db in try db.execute(sql: "UPDATE tracks SET album = 'Real Album' WHERE id = ?", arguments: [gone]) }
        let items = try await repo.pending(filter: .suggestions)
        #expect(items.map(\.id) == [b, a])
        let counts = try await repo.counts()
        #expect(counts.pending == 2 && counts.rows == 5 && counts.noMatch == 0 && counts.noAlbum == 0)
    }

    @Test func noMatchAndNoAlbumFiltersHaveTheirOwnLists() async throws {
        let queue = try DatabaseManager.inMemory()
        let (a, b, c): (Int64, Int64, Int64) = try await queue.write { db in
            (try Self.track(db, "A"), try Self.track(db, "B"), try Self.track(db, "C"))
        }
        let repo = AlbumSuggestionRepository(database: queue)
        try await repo.upsert([AlbumSuggestionRow.looked(up: a, candidates: []), Self.row(b, "Album", status: .noAlbum)])
        try await repo.setNoAlbum(true, trackIDs: [b, c])
        #expect(try await repo.pending(filter: .noMatch).map(\.id) == [a])
        #expect(Set(try await repo.pending(filter: .noAlbum).map(\.id)) == [b, c])
        let counts = try await repo.counts()
        #expect(counts.noMatch == 1 && counts.noAlbum == 2 && counts.pending == 0)
    }

    @Test func lookupCandidatesSkipRowsRealAlbumsNoAlbumAndUnlistedTracks() async throws {
        let queue = try DatabaseManager.inMemory()
        let ids: [Int64] = try await queue.write { db in
            let open = try Self.track(db, "Open")
            let source = try Self.track(db, "Source named", album: "SoundCloud")
            let unknown = try Self.track(db, "Unknown", album: "unknown album")
            let real = try Self.track(db, "Real", album: "Some Album")
            let decided = try Self.track(db, "Decided")
            let looked = try Self.track(db, "Looked")
            let hidden = try Self.track(db, "Hidden")
            try db.execute(sql: "UPDATE tracks SET no_album = 1 WHERE id = ?", arguments: [decided])
            try db.execute(sql: "UPDATE tracks SET hidden_by_review = 1 WHERE id = ?", arguments: [hidden])
            return [open, source, unknown, real, decided, looked, hidden]
        }
        let repo = AlbumSuggestionRepository(database: queue)
        try await repo.upsert([Self.row(ids[5], "Done")])
        let candidates = try await repo.candidatesForLookup().compactMap(\.id)
        #expect(candidates == [ids[0], ids[1], ids[2]])
        #expect(try await repo.candidatesForLookup(limit: 2).count == 2)
        #expect(try await repo.candidateCount() == 3)
    }

    @Test func aboveFiltersByMatchStrictly() async throws {
        let queue = try DatabaseManager.inMemory()
        let ids: [Int64] = try await queue.write { db in
            [try Self.track(db, "A"), try Self.track(db, "B"), try Self.track(db, "C")]
        }
        let repo = AlbumSuggestionRepository(database: queue)
        try await repo.upsert([Self.row(ids[0], "A", match: 95), Self.row(ids[1], "B", match: 90), Self.row(ids[2], "C", match: 90.5)])
        #expect(Set(try await repo.pending(above: 90).map(\.id)) == [ids[0], ids[2]])
    }

    // MARK: Decisions

    @Test func setStatusReturnsTheRowsAsTheyWereAndRestoreBringsThemBack() async throws {
        let queue = try DatabaseManager.inMemory()
        let id = try await queue.write { db in try Self.track(db, "Song") }
        let repo = AlbumSuggestionRepository(database: queue)
        try await repo.upsert([Self.row(id, "A")])
        let before = try await repo.setStatus(.rejected, trackIDs: [id, id, 999], decidedAt: "2026-10-06T10:00:00Z")
        #expect(before.map(\.status) == [.pending])
        let after = try #require(try await repo.row(trackID: id))
        #expect(after.status == .rejected && after.decidedAt == "2026-10-06T10:00:00Z")
        try await repo.restore(before)
        #expect(try await repo.row(trackID: id) == before[0])
        try await repo.restore([], removing: [id])
        #expect(try await repo.row(trackID: id) == nil)
    }

    @Test func noAlbumFlagReportsWhatChanged() async throws {
        let queue = try DatabaseManager.inMemory()
        let (a, b): (Int64, Int64) = try await queue.write { db in (try Self.track(db, "A"), try Self.track(db, "B")) }
        let repo = AlbumSuggestionRepository(database: queue)
        #expect(try await repo.setNoAlbum(true, trackIDs: [a]) == [a])
        #expect(try await repo.setNoAlbum(true, trackIDs: [a, b]) == [b], "a track already marked is not reported")
        #expect(try await repo.setNoAlbum(false, trackIDs: [a, b]) == [a, b])
    }

    // MARK: Cascade

    @Test func deletingATrackDeletesItsSuggestion() async throws {
        let queue = try DatabaseManager.inMemory()
        let (a, b): (Int64, Int64) = try await queue.write { db in (try Self.track(db, "A"), try Self.track(db, "B")) }
        let suggestions = AlbumSuggestionRepository(database: queue)
        try await suggestions.upsert([Self.row(a, "X"), Self.row(b, "Y")])
        try await TrackRepository(database: queue).delete(ids: [a])
        #expect(try await suggestions.row(trackID: a) == nil)
        #expect(try await suggestions.row(trackID: b) != nil)
    }

    @Test func deletingATrackToleratesADatabaseWithoutTheTable() async throws {
        let queue = try DatabaseQueue(configuration: AlbumTracksMigrationTests.configuration)
        try DatabaseManager.buildMigrator().migrate(queue, upTo: Self.previous)
        let id = try await queue.write { db in try Self.track(db, "A") }
        try await TrackRepository(database: queue).delete(ids: [id])
        #expect(try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") } == 0)
    }
}
