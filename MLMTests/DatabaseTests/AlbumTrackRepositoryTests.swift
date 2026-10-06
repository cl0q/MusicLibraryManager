import Foundation
import GRDB
import Testing
@testable import MLM

/// `AlbumTrackRepository` (W4-1, IMP-067): order, numbers, exact-row undo, cascades.
@Suite("AlbumTrackRepositoryTests")
struct AlbumTrackRepositoryTests {
    struct Fixture {
        let db: DatabaseQueue
        let repo: AlbumTrackRepository
        let album: Int64
        let ids: [Int64]

        init(tracks: Int = 4) throws {
            db = try DatabaseManager.inMemory()
            repo = AlbumTrackRepository(database: db)
            (album, ids) = try db.write { db in
                try db.execute(sql: "INSERT INTO albums (artist, album_artist, title, title_normalized) VALUES ('O','O','Good Lies','goodlies')")
                let album = db.lastInsertedRowID
                let ids = try (0..<tracks).map { index in
                    try AlbumTracksMigrationTests.insertTrack(db, title: "T\(index)", album: "Good Lies")
                }
                return (album, ids)
            }
        }
    }

    @Test func addAppendsInOrderLinksTheTrackAndSkipsMembers() async throws {
        let f = try Fixture()
        let added = try await f.repo.add(trackIDs: [f.ids[2], f.ids[0], f.ids[2], 9_999], to: f.album)
        #expect(added.map(\.trackId) == [f.ids[2], f.ids[0]], "missing tracks and repeats are skipped")
        let again = try await f.repo.add(trackIDs: [f.ids[0], f.ids[1]], to: f.album)
        #expect(again.map(\.trackId) == [f.ids[1]])
        #expect(try await f.repo.rows(of: f.album).map(\.trackId) == [f.ids[2], f.ids[0], f.ids[1]])
        let link = try await f.db.read { db in try Int64.fetchOne(db, sql: "SELECT album_id FROM tracks WHERE id = ?", arguments: [f.ids[2]]) }
        #expect(link == f.album)
        let membership = try await f.repo.membership(trackID: f.ids[2])
        #expect(membership.map(\.albumId) == [f.album])
    }

    @Test func addToAMissingAlbumThrows() async throws {
        let f = try Fixture()
        await #expect(throws: AlbumTrackRepositoryError.albumNotFound) {
            try await f.repo.add(trackIDs: [f.ids[0]], to: 12_345)
        }
    }

    @Test func removeDeletesTheRowAndClearsTheLink() async throws {
        let f = try Fixture()
        try await f.repo.add(trackIDs: f.ids, to: f.album)
        let removed = try await f.repo.remove(trackIDs: [f.ids[1], 77], from: f.album)
        #expect(removed.map(\.trackId) == [f.ids[1]])
        #expect(try await f.repo.rows(of: f.album).count == 3)
        let link = try await f.db.read { db in try Int64?.fetchOne(db, sql: "SELECT album_id FROM tracks WHERE id = ?", arguments: [f.ids[1]]) }
        #expect(link == .some(nil))
    }

    @Test func moveReordersAndKeepsTheOthers() async throws {
        let f = try Fixture()
        try await f.repo.add(trackIDs: f.ids, to: f.album)
        #expect(try await f.repo.move(trackIDs: [f.ids[3]], to: 0, in: f.album))
        #expect(try await f.repo.rows(of: f.album).map(\.trackId) == [f.ids[3], f.ids[0], f.ids[1], f.ids[2]])
        #expect(try await f.repo.move(trackIDs: [f.ids[0], f.ids[3]], to: 2, in: f.album))
        #expect(try await f.repo.rows(of: f.album).map(\.trackId) == [f.ids[1], f.ids[2], f.ids[0], f.ids[3]])
        #expect(try await f.repo.move(trackIDs: [f.ids[3]], to: 99, in: f.album) == false, "already last: nothing changes")
        #expect(try await f.repo.move(trackIDs: [4_242], to: 0, in: f.album) == false)
    }

    @Test func moveRenumbersWhenNoKeyFits() async throws {
        let f = try Fixture(tracks: 3)
        try await f.repo.add(trackIDs: f.ids, to: f.album)
        // Squeeze the first two rows so nothing sorts between them (`a0` then `a00`).
        try await f.db.write { db in
            try db.execute(sql: "UPDATE album_tracks SET position = 'b0' WHERE track_id = ?", arguments: [f.ids[0]])
            try db.execute(sql: "UPDATE album_tracks SET position = 'b00' WHERE track_id = ?", arguments: [f.ids[1]])
            try db.execute(sql: "UPDATE album_tracks SET position = 'b1' WHERE track_id = ?", arguments: [f.ids[2]])
        }
        _ = try await f.repo.move(trackIDs: [f.ids[2]], to: 1, in: f.album)
        let rows = try await f.repo.rows(of: f.album)
        #expect(rows.map(\.trackId) == [f.ids[0], f.ids[2], f.ids[1]])
        #expect(rows.map(\.position) == rows.map(\.position).sorted(), "positions stay in order")
        #expect(Set(rows.map(\.position)).count == 3)
    }

    @Test func moveToADiscTakesTheDiscOfTheRowBefore() async throws {
        let f = try Fixture()
        try await f.repo.add(trackIDs: f.ids, to: f.album)
        try await f.db.write { db in try db.execute(sql: "UPDATE album_tracks SET disc = 2 WHERE track_id IN (?, ?)", arguments: [f.ids[2], f.ids[3]]) }
        _ = try await f.repo.move(trackIDs: [f.ids[0]], to: 3, in: f.album)
        let rows = try await f.repo.rows(of: f.album)
        #expect(rows.map(\.trackId) == [f.ids[1], f.ids[2], f.ids[3], f.ids[0]])
        #expect(rows.last?.disc == 2)
    }

    @Test func setNumbersResortsOnlyWhenEveryMemberHasOne() async throws {
        let f = try Fixture(tracks: 3)
        try await f.repo.add(trackIDs: f.ids, to: f.album)
        let partial = try await f.repo.setNumbers(albumID: f.album, [f.ids[0]: (1, 3), f.ids[1]: (1, 1)])
        #expect(partial == AlbumNumbering(changed: 2, resorted: false))
        #expect(try await f.repo.rows(of: f.album).map(\.trackId) == f.ids, "order untouched while a member has no number")
        let full = try await f.repo.setNumbers(albumID: f.album, [f.ids[2]: (1, 2)])
        #expect(full == AlbumNumbering(changed: 1, resorted: true))
        let rows = try await f.repo.rows(of: f.album)
        #expect(rows.map(\.trackId) == [f.ids[1], f.ids[2], f.ids[0]])
        #expect(rows.map(\.trackNumber) == [1, 2, 3])
        let same = try await f.repo.setNumbers(albumID: f.album, [f.ids[2]: (1, 2)])
        #expect(same.changed == 0)
    }

    @Test func discsSortBeforeNumbers() async throws {
        let f = try Fixture(tracks: 4)
        try await f.repo.add(trackIDs: f.ids, to: f.album)
        _ = try await f.repo.setNumbers(albumID: f.album, [f.ids[0]: (2, 1), f.ids[1]: (1, 2), f.ids[2]: (2, 2), f.ids[3]: (1, 1)])
        #expect(try await f.repo.rows(of: f.album).map(\.trackId) == [f.ids[3], f.ids[1], f.ids[0], f.ids[2]])
    }

    @Test func tracksOfAppliesVisibilityAndOrder() async throws {
        let f = try Fixture()
        try await f.repo.add(trackIDs: f.ids, to: f.album)
        try await f.db.write { db in try db.execute(sql: "UPDATE tracks SET hidden_by_review = 1 WHERE id = ?", arguments: [f.ids[1]]) }
        _ = try await f.repo.move(trackIDs: [f.ids[3]], to: 0, in: f.album)
        let tracks = try await f.repo.tracks(of: f.album)
        #expect(tracks.compactMap(\.id) == [f.ids[3], f.ids[0], f.ids[2]])
        #expect(try await f.repo.rows(of: f.album).count == 4, "hidden tracks keep their row")
    }

    @Test func snapshotAndRestoreUndoEachEditExactly() async throws {
        let f = try Fixture()
        try await f.repo.add(trackIDs: [f.ids[0], f.ids[1]], to: f.album)
        _ = try await f.repo.setNumbers(albumID: f.album, [f.ids[0]: (1, 5)])
        let before = try await f.repo.snapshot(albumID: f.album)

        try await f.repo.add(trackIDs: [f.ids[2]], to: f.album)
        _ = try await f.repo.move(trackIDs: [f.ids[2]], to: 0, in: f.album)
        let after = try await f.repo.snapshot(albumID: f.album)
        try await f.repo.restore(before)
        #expect(try await f.repo.snapshot(albumID: f.album) == before, "undo of add + move")
        try await f.repo.restore(after)
        #expect(try await f.repo.snapshot(albumID: f.album) == after, "redo")
        try await f.repo.restore(before)

        try await f.repo.remove(trackIDs: [f.ids[0]], from: f.album)
        try await f.repo.restore(before)
        let snapshot = try await f.repo.snapshot(albumID: f.album)
        #expect(snapshot == before, "undo of remove restores the row (with its number) and the link")
        #expect(snapshot.rows.first { $0.trackId == f.ids[0] }?.trackNumber == 5)
    }

    @Test func restoreSkipsTracksThatLeftTheLibrary() async throws {
        let f = try Fixture(tracks: 2)
        try await f.repo.add(trackIDs: f.ids, to: f.album)
        let snapshot = try await f.repo.snapshot(albumID: f.album)
        try await f.db.write { db in
            try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [f.ids[0]])
        }
        try await f.repo.restore(snapshot)
        #expect(try await f.repo.rows(of: f.album).map(\.trackId) == [f.ids[1]])
    }

    @Test func deletingATrackRemovesItsRows() async throws {
        let f = try Fixture()
        try await f.repo.add(trackIDs: f.ids, to: f.album)
        try await TrackRepository(database: f.db).delete(ids: [f.ids[0], f.ids[1]])
        #expect(try await f.repo.rows(of: f.album).map(\.trackId) == [f.ids[2], f.ids[3]])
        #expect(try await f.repo.membership(trackID: f.ids[0]).isEmpty)
    }

    @Test func deletingAnAlbumRemovesItsRowsPrefsAndLinks() async throws {
        let f = try Fixture(tracks: 2)
        try await f.repo.add(trackIDs: f.ids, to: f.album)
        let variant: Int64 = try await f.db.write { db in
            try db.execute(sql: "INSERT INTO albums (artist, album_artist, title, title_normalized, variant_of, variant_kind) VALUES ('O','O','Good Lies','goodlies', ?, 'deluxe')", arguments: [f.album])
            let variant = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO user_album_variant_pref VALUES ('default', ?, ?, 'now')", arguments: [f.album, variant])
            return variant
        }
        try await AlbumRepository(database: f.db).delete(id: f.album)
        let (rows, prefs, links, variantOf, albums) = try await f.db.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_tracks") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_album_variant_pref") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE album_id = ?", arguments: [f.album]) ?? -1,
             try Int64?.fetchOne(db, sql: "SELECT variant_of FROM albums WHERE id = ?", arguments: [variant]),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums WHERE id = ?", arguments: [f.album]) ?? -1)
        }
        #expect(rows == 0 && prefs == 0 && links == 0 && albums == 0)
        #expect(variantOf == .some(nil))
    }
}
