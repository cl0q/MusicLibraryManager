import Foundation
import GRDB
import Testing
@testable import MLM

/// `tracks.no_album` (v52, IMP-084/086): a confirmed `No album` leaves `is: no album`, the
/// Albums footer count and the lookup — and the SQL, the count and the in-memory filter agree.
/// The Review badge and tab count add the pending suggestions.
@Suite("NoAlbumConfirmationTests", .serialized)
@MainActor
struct NoAlbumConfirmationTests {
    nonisolated static func seed(_ db: Database) throws -> [String: Int64] {
        var ids: [String: Int64] = [:]
        for (key, album) in [("empty", ""), ("unknown", "unknown album"), ("source", "SoundCloud"), ("url", "https://x.example/a"),
                             ("real", "Good Lies"), ("flagged", ""), ("flaggedSource", "YouTube")] {
            ids[key] = try AlbumTracksMigrationTests.insertTrack(db, title: key, album: album)
        }
        try db.execute(sql: "UPDATE tracks SET no_album = 1 WHERE id IN (?, ?)", arguments: [ids["flagged"]!, ids["flaggedSource"]!])
        return ids
    }

    @Test func theSqlPredicateTheCountAndTheInMemoryFilterAgree() async throws {
        let db = try DatabaseManager.inMemory()
        let ids = try await db.write { db in try Self.seed(db) }
        let filter = SearchFilter(tokens: [.availability(.noAlbum)])
        let (sql, arguments) = TrackSearchSQL.predicate(for: filter)
        let inSQL = try await db.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM tracks WHERE \(sql) ORDER BY id", arguments: arguments)
        }
        let tracks = try await db.read { db in try Track.fetchAll(db, sql: "SELECT * FROM tracks ORDER BY id") }
        let inMemory = tracks.filter { filter.matches($0) }.compactMap(\.id)
        let expected = ["empty", "unknown", "source", "url"].compactMap { ids[$0] }
        #expect(inSQL == expected, "confirmed tracks are not `no album`, whatever their text")
        #expect(inMemory == expected)
        let count = try await TrackScopeQueries(database: db).noAlbumCount()
        #expect(count == expected.count)
    }

    @Test func trackRowsCarryTheFlagAndSavingATrackNeverChangesIt() async throws {
        let db = try DatabaseManager.inMemory()
        let ids = try await db.write { db in try Self.seed(db) }
        var track = try #require(try await db.read { db in try Track.fetchOne(db, key: ids["flagged"]!) })
        #expect(track.noAlbum)
        track.title = "Renamed"
        try await db.write { db in try track.update(db) }
        let flag = try await db.read { db in try Int.fetchOne(db, sql: "SELECT no_album FROM tracks WHERE id = ?", arguments: [ids["flagged"]!]) }
        #expect(flag == 1, "encode(to:) does not write it")
        let plain = try #require(try await db.read { db in try Track.fetchOne(db, key: ids["real"]!) })
        #expect(!plain.noAlbum)
    }

    @Test func theReviewTabCountsPendingSuggestionsAndShowsAfterTheFirstLookup() async throws {
        let env = try ReviewEnv.make()
        var dependencies = env.model.dependencies
        dependencies.albumSuggestions = AlbumSuggestionRepository(database: env.db)
        let model = ReviewModel(dependencies: dependencies, scan: env.runner, center: env.center)
        await model.reload()
        #expect(model.count(for: .albums) == 0 && !model.albumsLookedUp, "before the first lookup the tab stays hidden")

        let (a, b): (Int64, Int64) = try await env.db.write { db in
            (try AlbumTracksMigrationTests.insertTrack(db, title: "A", album: ""), try AlbumTracksMigrationTests.insertTrack(db, title: "B", album: ""))
        }
        let suggestion = AlbumSuggestion(albumTitle: "X", source: "Folder name", match: 80)
        try await dependencies.albumSuggestions?.upsert([
            AlbumSuggestionRow(trackID: a, suggestion: suggestion, alternatives: [], status: .pending, decidedAt: nil),
            AlbumSuggestionRow.looked(up: b, candidates: []),
        ])
        await model.reload()
        #expect(model.count(for: .albums) == 1, "no-match rows are not pending suggestions")
        #expect(model.albumsLookedUp)
        #expect(model.waitingCount == 1, "the badge adds them")
        let items = ReviewTab.allCases.map {
            ScopeBarItem(id: $0, title: $0.title, count: model.count(for: $0), hidesWhenEmpty: $0 == .albums && !model.albumsLookedUp)
        }
        #expect(ScopeBarRules.visibleItems(items, selection: .duplicates).map(\.id).contains(.albums))
    }

    @Test func theSidebarBadgeAddsPendingSuggestions() async throws {
        let db = try DatabaseManager.inMemory()
        let id = try await db.write { db in try AlbumTracksMigrationTests.insertTrack(db, title: "A", album: "") }
        let repository = AlbumSuggestionRepository(database: db)
        try await repository.upsert([AlbumSuggestionRow(trackID: id, suggestion: AlbumSuggestion(albumTitle: "X", source: "File name", match: 85),
                                                        alternatives: [], status: .pending, decidedAt: nil)])
        let sidebar = SidebarModel(defaults: UserDefaults(suiteName: "NoAlbumConfirmationTests-\(UUID().uuidString)")!)
        await sidebar.reloadBadges(trackRepository: nil, analysisRepository: AnalysisRepository(database: db), albumSuggestions: repository)
        #expect(sidebar.reviewCount == 1)
    }
}
