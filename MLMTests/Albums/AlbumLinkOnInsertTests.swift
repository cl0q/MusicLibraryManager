import Foundation
import GRDB
import Testing
@testable import MLM

/// Tracks inserted by downloads, remote-playlist imports and recommendations join their album
/// when the row carries a real album text (W4-3; before, only `ImportService.saveBatch` did).
@Suite("AlbumLinkOnInsertTests")
struct AlbumLinkOnInsertTests {
    static func track(_ title: String, album: String, artist: String = "Overmono") -> Track {
        var track = Track(artist: artist, album: album, title: title, format: "flac", originalPath: "/orig/\(title).flac")
        track.year = 2022
        return track
    }

    static func membership(_ db: DatabaseQueue, _ id: Int64) async throws -> (albumID: Int64?, joins: Int, title: String?) {
        try await db.read { db in
            let albumID = try Int64.fetchOne(db, sql: "SELECT album_id FROM tracks WHERE id = ?", arguments: [id])
            let joins = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_tracks WHERE track_id = ?", arguments: [id]) ?? 0
            let title = try albumID.flatMap { try String.fetchOne(db, sql: "SELECT title FROM albums WHERE id = ?", arguments: [$0]) }
            return (albumID, joins, title)
        }
    }

    @Test func aTrackInsertedWithAnAlbumJoinsIt() async throws {
        let db = try DatabaseManager.inMemory()
        let repository = TrackRepository(database: db)
        let first = try #require(try await repository.insert(Self.track("A", album: "Good Lies")).id)
        let second = try #require(try await repository.insert(Self.track("B", album: "good  lies")).id)
        let a = try await Self.membership(db, first)
        let b = try await Self.membership(db, second)
        #expect(a.title == "Good Lies" && a.joins == 1)
        #expect(a.albumID == b.albumID, "one album row for one album")
    }

    @Test func noAlbumSourceNamesAndURLsDoNotCreateAnAlbum() async throws {
        let db = try DatabaseManager.inMemory()
        let repository = TrackRepository(database: db)
        for album in ["", "SoundCloud", "unknown album", "https://example.com/x"] {
            let id = try #require(try await repository.insert(Self.track("T-\(album.count)", album: album)).id)
            let membership = try await Self.membership(db, id)
            #expect(membership.albumID == nil && membership.joins == 0, "“\(album)”")
        }
        let albums = try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums") }
        #expect(albums == 0)
    }

    @Test func aMaterializedRemoteTrackWithoutAlbumGetsNoLinkButOneWithAlbumDoes() async throws {
        let db = try DatabaseManager.inMemory()
        let sources = SourceRepository(database: db)
        let plain = try #require(try await sources.materializeRemoteTrack(Self.track("P", album: ""), sourceName: "soundcloud", externalId: "1"))
        let withAlbum = try #require(try await sources.materializeRemoteTrack(Self.track("Q", album: "Real Album"), sourceName: "spotify", externalId: "2"))
        let first = try await Self.membership(db, try #require(plain.id))
        let second = try await Self.membership(db, try #require(withAlbum.id))
        #expect(first.albumID == nil)
        #expect(second.title == "Real Album" && second.joins == 1)
    }

    @Test func aHeldRecommendationJoinsItsAlbumWhenItIsKept() async throws {
        let db = try DatabaseManager.inMemory()
        let recommendations = RecommendationRepository(database: db)
        let held = try #require(try await recommendations.insert(Self.track("H", album: "Good Lies"), hold: true, seedTrackID: nil, source: "test").id)
        let kept = try #require(try await recommendations.insert(Self.track("K", album: "Good Lies"), hold: false, seedTrackID: nil, source: "test").id)
        let beforeKeep = try await Self.membership(db, held)
        let keptNow = try await Self.membership(db, kept)
        #expect(beforeKeep.albumID == nil, "a held recommendation is not in the library yet")
        #expect(keptNow.title == "Good Lies")
        try await recommendations.keep(ids: [held])
        let afterKeep = try await Self.membership(db, held)
        #expect(afterKeep.albumID == keptNow.albumID && afterKeep.joins == 1)
    }

    @Test func aFailingLinkLeavesTheTrackInserted() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in try db.execute(sql: "DROP TABLE album_tracks") }
        let id = try #require(try await TrackRepository(database: db).insert(Self.track("A", album: "Good Lies")).id)
        let exists = try await db.read { db in try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tracks WHERE id = ?)", arguments: [id]) }
        #expect(exists == true)
        let albums = try await db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums") }
        #expect(albums == 0, "the savepoint took the half-made album back")
    }
}
