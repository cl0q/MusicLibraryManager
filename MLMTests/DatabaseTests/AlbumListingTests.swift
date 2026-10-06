import Foundation
import GRDB
import Testing
@testable import MLM

/// `AlbumRepository.fetchListed / scopeCounts / summary` and `TrackScopeQueries.noAlbumCount`
/// (W4-1, IMP-069/070).
@Suite("AlbumListingTests")
struct AlbumListingTests {
    final class Library {
        let db: DatabaseQueue
        let albums: AlbumRepository
        let joins: AlbumTrackRepository

        init() throws {
            db = try DatabaseManager.inMemory()
            albums = AlbumRepository(database: db)
            joins = AlbumTrackRepository(database: db)
        }

        /// An album with `count` tracks (artists: `trackArtists`, cycled), joined in order.
        @discardableResult
        func album(_ title: String, artist: String = "Overmono", year: Int? = nil, count: Int,
                   trackArtists: [String] = ["Overmono"], added: String = "2026-01-01 10:00:00",
                   genre: String? = nil, duration: Int = 100, numbers: [(Int, Int)]? = nil) async throws -> (id: Int64, tracks: [Int64]) {
            let (id, tracks): (Int64, [Int64]) = try await db.write { db in
                try db.execute(sql: "INSERT INTO albums (artist, album_artist, title, title_normalized, year) VALUES (?, ?, ?, ?, ?)",
                               arguments: [artist, artist, title, AlbumKey.normalize(title), year])
                let id = db.lastInsertedRowID
                var tracks: [Int64] = []
                for index in 0..<count {
                    let track = try AlbumTracksMigrationTests.insertTrack(
                        db, title: "\(title) \(index)", artist: trackArtists[index % trackArtists.count], album: title, albumID: id, year: year)
                    try db.execute(sql: "UPDATE tracks SET date_added = ?, genre = ?, duration = ? WHERE id = ?",
                                   arguments: [added, genre, duration, track])
                    tracks.append(track)
                }
                return (id, tracks)
            }
            try await joins.add(trackIDs: tracks, to: id)
            if let numbers {
                var map: [Int64: (disc: Int, number: Int)] = [:]
                for (track, number) in zip(tracks, numbers) { map[track] = (number.0, number.1) }
                try await joins.setNumbers(albumID: id, map)
            }
            return (id, tracks)
        }

        func titles(_ scope: AlbumScope = .all, _ sort: AlbumSort = .artist, _ filter: SearchFilter = .empty) async throws -> [String] {
            try await albums.fetchListed(scope: scope, sort: sort, filter: filter).map(\.album.title)
        }
    }

    @Test func theGridListsAlbumsWithTwoTracksOrATracklistNumberedPastOne() async throws {
        let lib = try Library()
        try await lib.album("Two", count: 2)
        try await lib.album("One", count: 1)
        try await lib.album("Single Numbered", count: 1, numbers: [(1, 1)])
        try await lib.album("Track Two Of A Release", count: 1, numbers: [(1, 2)])
        #expect(try await lib.titles(.all, .title) == ["Track Two Of A Release", "Two"],
                "a single track numbered 1 is not a tracklist; one numbered 2 or more is")
        #expect(try await lib.albums.scopeCounts(filter: .empty)[.all] == 2)
    }

    @Test func completeAndIncompleteFollowTheKnownTracklist() async throws {
        let lib = try Library()
        try await lib.album("No Tracklist", count: 3)
        try await lib.album("Filled", count: 3, numbers: [(1, 1), (1, 2), (1, 3)])
        try await lib.album("Gap", count: 3, numbers: [(1, 1), (1, 3), (1, 4)])
        try await lib.album("Two Discs", count: 4, numbers: [(1, 1), (1, 2), (2, 1), (2, 2)])
        try await lib.album("Disc Two Gap", count: 3, numbers: [(1, 1), (1, 2), (2, 2)])
        try await lib.album("Partly Numbered", count: 3, numbers: [(1, 1)])
        #expect(try await lib.titles(.complete, .title) == ["Filled", "No Tracklist", "Partly Numbered", "Two Discs"])
        #expect(try await lib.titles(.incomplete, .title) == ["Disc Two Gap", "Gap"])
        let gap = try #require(try await lib.albums.fetchListed(scope: .incomplete).first { $0.album.title == "Gap" })
        #expect(gap.tracklist.expectedCount == 4 && gap.tracklist.presentCount == 3, "Incomplete · 3 of 4")
        let counts = try await lib.albums.scopeCounts()
        #expect(counts[.all] == 6 && counts[.complete] == 4 && counts[.incomplete] == 2 && counts[.compilations] == 0)
    }

    @Test func compilationsAreVariousArtistsOrThreeArtists() async throws {
        let lib = try Library()
        try await lib.album("Mix", artist: "VARIOUS ARTISTS", count: 2)
        try await lib.album("Split", artist: "Bicep", count: 3, trackArtists: ["Bicep", "Overmono", "Lone"])
        try await lib.album("Collab", artist: "Bicep", count: 4, trackArtists: ["Bicep", "overmono", "BICEP", "Overmono"])
        #expect(try await lib.titles(.compilations, .title) == ["Mix", "Split"])
    }

    @Test func hiddenAndHeldTracksAreNotCounted() async throws {
        let lib = try Library()
        let (_, tracks) = try await lib.album("Pair", count: 2)
        try await lib.db.write { db in try db.execute(sql: "UPDATE tracks SET hidden_by_review = 1 WHERE id = ?", arguments: [tracks[0]]) }
        #expect(try await lib.titles().isEmpty, "one listed track left")
        try await lib.db.write { db in try db.execute(sql: "UPDATE tracks SET hidden_by_review = 0 WHERE id = ?", arguments: [tracks[0]]) }
        #expect(try await lib.titles() == ["Pair"])
        try await lib.db.write { db in try db.execute(sql: "UPDATE tracks SET is_pending_recommendation = 1 WHERE id = ?", arguments: [tracks[1]]) }
        #expect(try await lib.titles().isEmpty)
    }

    @Test func nonAlbumsAndEditionsAreNotListed() async throws {
        let lib = try Library()
        try await lib.album("SoundCloud", count: 3)
        try await lib.album("unknown album", count: 3)
        let base = try await lib.album("Real", count: 2)
        let edition = try await lib.album("Real Deluxe", count: 2)
        try await lib.db.write { db in
            try db.execute(sql: "UPDATE albums SET variant_of = ?, variant_kind = 'deluxe', title = 'Real' WHERE id = ?",
                           arguments: [base.id, edition.id])
        }
        #expect(try await lib.titles() == ["Real"])
    }

    @Test func sortOrders() async throws {
        let lib = try Library()
        try await lib.album("Zed", artist: "Bicep", year: 2017, count: 2, added: "2026-03-01 00:00:00")
        try await lib.album("Alpha", artist: "Bicep", year: 2021, count: 2, added: "2026-01-01 00:00:00")
        try await lib.album("Mid", artist: "Aphex Twin", year: 2014, count: 2, added: "2026-02-01 00:00:00")
        try await lib.album("Nowhen", artist: "Lone", year: nil, count: 2, added: "2025-12-01 00:00:00")
        #expect(try await lib.titles(.all, .artist) == ["Mid", "Zed", "Alpha", "Nowhen"], "artist, then year (oldest first)")
        #expect(try await lib.titles(.all, .title) == ["Alpha", "Mid", "Nowhen", "Zed"])
        #expect(try await lib.titles(.all, .year) == ["Alpha", "Zed", "Mid", "Nowhen"], "newest first, no year last")
        #expect(try await lib.titles(.all, .recentlyAdded) == ["Zed", "Mid", "Alpha", "Nowhen"], "newest first")
    }

    @Test func theFilterMatchesTitleAndAlbumArtistAndCountsFollow() async throws {
        let lib = try Library()
        try await lib.album("Low Season", artist: "Overmono", year: 2019, count: 2)
        try await lib.album("Syro", artist: "Aphex Twin", year: 2014, count: 2)
        try await lib.album("Mix", artist: "Various Artists", count: 2)
        #expect(try await lib.titles(.all, .title, SearchFilter(text: "overmono")) == ["Low Season"])
        #expect(try await lib.titles(.all, .title, SearchFilter(text: "SYRO")) == ["Syro"])
        #expect(try await lib.titles(.all, .title, SearchFilter(text: "low overmono")) == ["Low Season"])
        let counts = try await lib.albums.scopeCounts(filter: SearchFilter(text: "various"))
        #expect(counts[.all] == 1 && counts[.compilations] == 1 && counts[.incomplete] == 0)
    }

    @Test func theSummaryIsYearGenreCountAndDurationOfListedTracks() async throws {
        let lib = try Library()
        let (id, tracks) = try await lib.album("Low Season", year: nil, count: 4, genre: "Techno", duration: 600)
        try await lib.db.write { db in
            try db.execute(sql: "UPDATE tracks SET genre = 'House' WHERE id = ?", arguments: [tracks[0]])
            try db.execute(sql: "UPDATE tracks SET year = 2019 WHERE id IN (?, ?, ?)", arguments: [tracks[0], tracks[1], tracks[2]])
            try db.execute(sql: "UPDATE tracks SET year = 2020 WHERE id = ?", arguments: [tracks[3]])
            try db.execute(sql: "UPDATE tracks SET hidden_by_review = 1 WHERE id = ?", arguments: [tracks[3]])
        }
        let summary = try #require(try await lib.albums.summary(id: id))
        #expect(summary == AlbumSummary(year: 2019, genre: "Techno", trackCount: 3, duration: 1800))
        #expect(try await lib.albums.summary(id: 9_999) == nil)
        try await lib.db.write { db in try db.execute(sql: "UPDATE albums SET year = 2018 WHERE id = ?", arguments: [id]) }
        #expect(try await lib.albums.summary(id: id)?.year == 2018, "the album's own year wins")
    }

    @Test func noAlbumCountCountsListedTracksWithoutAnAlbum() async throws {
        let lib = try Library()
        let ids: [Int64] = try await lib.db.write { db in
            [try AlbumTracksMigrationTests.insertTrack(db, title: "a", album: ""),
             try AlbumTracksMigrationTests.insertTrack(db, title: "b", album: "unknown album"),
             try AlbumTracksMigrationTests.insertTrack(db, title: "c", album: "SoundCloud"),
             try AlbumTracksMigrationTests.insertTrack(db, title: "d", album: "https://example.com/x"),
             try AlbumTracksMigrationTests.insertTrack(db, title: "hidden", album: ""),
             try AlbumTracksMigrationTests.insertTrack(db, title: "real", album: "Good Lies")]
        }
        try await lib.db.write { db in try db.execute(sql: "UPDATE tracks SET hidden_by_review = 1 WHERE id = ?", arguments: [ids[4]]) }
        let queries = TrackScopeQueries(database: lib.db)
        #expect(try await queries.noAlbumCount() == 4)
        // The `is: no album` token (W2-I) selects the same tracks.
        let (predicateSQL, predicateArguments) = TrackSearchSQL.predicate(for: SearchFilter(tokens: [.availability(.noAlbum)]))
        let viaToken = try await lib.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE \(TrackVisibility.listed(predicateSQL))", arguments: predicateArguments)
        }
        #expect(viaToken == 4)
        #expect(SearchAvailabilityWord.allCases.contains(.noAlbum))
    }
}
