import Foundation
import GRDB
import Testing
@testable import MLM

/// The reads and writes the album surfaces add (W4-2): members with their numbers, what Download
/// Missing fetches, the first track, editions, what removing an album removes, the disc-aware
/// order of Edit Order and pruning an emptied album.
@Suite("AlbumPageQueriesTests")
struct AlbumPageQueriesTests {
    typealias Library = AlbumListingTests.Library

    @Test func membersComeInAlbumOrderWithDiscAndNumber() async throws {
        let lib = try Library()
        let (id, tracks) = try await lib.album("Low Season", count: 4, numbers: [(1, 2), (1, 1), (2, 1), (2, 2)])
        let members = try await lib.albums.members(of: id)
        // `setNumbers` re-sorts the positions by (disc, number) once every member has a number.
        #expect(members.map { $0.track.id } == [tracks[1], tracks[0], tracks[2], tracks[3]])
        #expect(members.map(\.disc) == [1, 1, 2, 2])
        #expect(members.map(\.number) == [1, 2, 1, 2])
    }

    @Test func hiddenTracksAreNotMembersOfThePage() async throws {
        let lib = try Library()
        let (id, tracks) = try await lib.album("Low Season", count: 3)
        try await lib.db.write { db in try db.execute(sql: "UPDATE tracks SET hidden_by_review = 1 WHERE id = ?", arguments: [tracks[1]]) }
        #expect(try await lib.albums.members(of: id).count == 2)
        #expect(try await lib.joins.rows(of: id).count == 3, "the join keeps them")
    }

    @Test func downloadMissingCountsTracksWithoutAFileThatAreNotRunning() async throws {
        let lib = try Library()
        let (id, tracks) = try await lib.album("Low Season", count: 5)
        try await lib.db.write { db in
            try db.execute(sql: "UPDATE tracks SET organized_path = 'a/b.flac' WHERE id = ?", arguments: [tracks[0]])
            try db.execute(sql: "UPDATE tracks SET organized_path = NULL, download_status = 'downloading' WHERE id = ?", arguments: [tracks[1]])
            try db.execute(sql: "UPDATE tracks SET organized_path = NULL, download_status = 'failed' WHERE id = ?", arguments: [tracks[2]])
            try db.execute(sql: "UPDATE tracks SET organized_path = NULL, download_status = NULL WHERE id IN (?, ?)", arguments: [tracks[3], tracks[4]])
        }
        #expect(try await lib.albums.downloadableCounts()[id] == 3, "failed and not downloaded; not the file, not the running one")
    }

    @Test func theFirstTrackIsTheFirstInAlbumOrder() async throws {
        let lib = try Library()
        let (one, tracksOne) = try await lib.album("One", count: 3, numbers: [(1, 3), (1, 1), (1, 2)])
        let (two, tracksTwo) = try await lib.album("Two", artist: "Skee Mask", count: 2)
        let firsts = try await lib.albums.firstTrackIDs()
        #expect(firsts[one] == tracksOne[1])
        #expect(firsts[two] == tracksTwo[0])
    }

    @Test func editionStatsCountWhatTheLibraryHoldAgainstTheTracklist() async throws {
        let lib = try Library()
        let (id, _) = try await lib.album("Low Season", count: 3, numbers: [(1, 1), (1, 2), (1, 5)])
        let (other, _) = try await lib.album("Low Season (Deluxe)", count: 2)
        let stats = try await lib.albums.editionStats(ids: [id, other])
        #expect(stats[id] == AlbumEditionStat(albumID: id, inLibrary: 3, total: 5))
        #expect(stats[other] == AlbumEditionStat(albumID: other, inLibrary: 2, total: 2), "no numbers: the library's own count")
    }

    @Test func removingAnAlbumCountsItsTracksPlaylistsAndSyncProfiles() async throws {
        let lib = try Library()
        let (id, tracks) = try await lib.album("Low Season", count: 3)
        try await lib.db.write { db in
            try db.execute(sql: "INSERT INTO playlists (name, category) VALUES ('A', 'local'), ('B', 'local')")
            for playlist in [1, 2] {
                try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)",
                               arguments: [playlist, tracks[0], "a\(playlist)"])
            }
            try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (1, ?, 'b')", arguments: [tracks[1]])
            try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder) VALUES ('iPod', '/tmp/x')")
            try db.execute(sql: "INSERT INTO sync_profile_tracks (profile_id, track_id) VALUES (1, ?)", arguments: [tracks[2]])
        }
        let impact = try await lib.albums.removalImpact(albumIDs: [id])
        #expect(impact.trackIDs == tracks)
        #expect(impact.playlists == 2)
        #expect(impact.syncProfiles == 1)
        let none = try await lib.albums.removalImpact(albumIDs: [])
        #expect(none.trackIDs.isEmpty)
    }

    @Test func anAlbumThatLostItsLastTrackGoesWithItAndOneThatStillHasMembersStays() async throws {
        let lib = try Library()
        let (empty, emptyTracks) = try await lib.album("Gone", count: 2)
        let (kept, keptTracks) = try await lib.album("Kept", count: 2)
        // The track path deletes the rows of the removed tracks (manual cascades).
        let tracks = TrackRepository(database: lib.db)
        try await tracks.delete(ids: emptyTracks + [keptTracks[0]])
        #expect(try await lib.albums.fetch(id: empty) != nil, "the track path leaves the album row")
        #expect(try await lib.albums.deleteEmpty(ids: [empty, kept]) == 1)
        #expect(try await lib.albums.fetch(id: empty) == nil)
        #expect(try await lib.albums.fetch(id: kept) != nil)
        #expect(try await lib.joins.rows(of: kept).map(\.trackId) == [keptTracks[1]])
    }

    @Test func coverPathAndEditionPreferenceCanBeSetAndCleared() async throws {
        let lib = try Library()
        let (id, _) = try await lib.album("Low Season", count: 2)
        #expect(try await lib.albums.setCoverPath(albumID: id, to: "playlist-covers/album-1-a.png") == nil)
        #expect(try await lib.albums.fetch(id: id)?.coverPath == "playlist-covers/album-1-a.png")
        #expect(try await lib.albums.setCoverPath(albumID: id, to: nil) == "playlist-covers/album-1-a.png")
        #expect(try await lib.albums.fetch(id: id)?.coverPath == nil)
        try await lib.albums.setVariantPref(baseAlbumId: id, selectedAlbumId: id)
        #expect(try await lib.albums.fetchVariantPref(baseAlbumId: id) == id)
        try await lib.albums.clearVariantPref(baseAlbumId: id)
        #expect(try await lib.albums.fetchVariantPref(baseAlbumId: id) == nil)
    }

    // MARK: Edit Order's Done

    @Test func applyLayoutKeepsDiscsAndWritesNumbersWithinEachDisc() async throws {
        let lib = try Library()
        let (id, tracks) = try await lib.album("Low Season", count: 4, numbers: [(1, 1), (1, 2), (2, 1), (2, 2)])
        // Disc 2's first track moves to the front of disc 1; the other three keep their discs.
        let changed = try await lib.joins.applyLayout(albumID: id, [
            (tracks[2], 1, 1), (tracks[0], 1, 2), (tracks[1], 1, 3), (tracks[3], 2, 1),
        ])
        #expect(changed)
        let rows = try await lib.joins.rows(of: id)
        #expect(rows.map(\.trackId) == [tracks[2], tracks[0], tracks[1], tracks[3]])
        #expect(rows.map(\.disc) == [1, 1, 1, 2])
        #expect(rows.map(\.trackNumber) == [1, 2, 3, 1])
        let again = try await lib.joins.applyLayout(albumID: id, [(tracks[2], 1, 1), (tracks[0], 1, 2), (tracks[1], 1, 3), (tracks[3], 2, 1)])
        #expect(!again, "the same layout changes nothing")
    }

    @Test func applyLayoutKeepsHiddenMembersAfterTheirDisc() async throws {
        let lib = try Library()
        let (id, tracks) = try await lib.album("Low Season", count: 3)
        try await lib.db.write { db in try db.execute(sql: "UPDATE tracks SET hidden_by_review = 1 WHERE id = ?", arguments: [tracks[0]]) }
        _ = try await lib.joins.applyLayout(albumID: id, [(tracks[2], 1, 1), (tracks[1], 1, 2)])
        let rows = try await lib.joins.rows(of: id)
        #expect(rows.map(\.trackId) == [tracks[2], tracks[1], tracks[0]])
        #expect(rows.last?.trackNumber == nil, "the hidden one keeps what it had")
    }
}
