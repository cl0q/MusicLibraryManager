import Testing
import GRDB
@testable import MLM

struct PlaylistMembershipTests {

    // MARK: - Helpers

    private func makeRepo() throws -> (DatabaseQueue, PlaylistRepository) {
        let db = try DatabaseManager.inMemory()
        let repo = PlaylistRepository(database: db)
        return (db, repo)
    }

    private func seedTrack(in db: DatabaseQueue, id: Int64) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, date_added)
                VALUES (?, 'A', 'A', 'Album', 'Track', 'mp3', '/tmp/t.mp3', '2025-01-01T00:00:00Z')
            """, arguments: [id])
        }
    }

    // MARK: - Tests

    @Test func fetchPlaylists_returnsOnlyPlaylistsContainingTrack() async throws {
        let (db, repo) = try makeRepo()
        let a = try await repo.create(name: "Alpha")
        let b = try await repo.create(name: "Beta")
        let c = try await repo.create(name: "Charlie")

        try await seedTrack(in: db, id: 1)
        try await repo.addTrack(playlistId: a.id!, trackId: 1, position: "0.5")
        try await repo.addTrack(playlistId: b.id!, trackId: 1, position: "0.5")

        let result = try await repo.fetchPlaylists(forTrackId: 1)
        let names = Set(result.map(\.name))
        #expect(names == ["Alpha", "Beta"])
        #expect(!result.contains(where: { $0.id == c.id }))
    }

    @Test func fetchPlaylists_emptyWhenTrackInNoPlaylist() async throws {
        let (_, repo) = try makeRepo()
        _ = try await repo.create(name: "Alpha")

        let result = try await repo.fetchPlaylists(forTrackId: 999)
        #expect(result.isEmpty)
    }

    @Test func removeTrack_makesPlaylistDisappearFromMembership() async throws {
        let (db, repo) = try makeRepo()
        let a = try await repo.create(name: "Alpha")
        let b = try await repo.create(name: "Beta")

        try await seedTrack(in: db, id: 1)
        try await repo.addTrack(playlistId: a.id!, trackId: 1, position: "0.5")
        try await repo.addTrack(playlistId: b.id!, trackId: 1, position: "0.5")

        try await repo.removeTrack(playlistId: a.id!, trackId: 1)

        let result = try await repo.fetchPlaylists(forTrackId: 1)
        let names = result.map(\.name)
        #expect(names == ["Beta"])
    }

    @Test func reAdd_makesPlaylistReappear() async throws {
        let (db, repo) = try makeRepo()
        let a = try await repo.create(name: "Alpha")

        try await seedTrack(in: db, id: 1)
        try await repo.addTrack(playlistId: a.id!, trackId: 1, position: "0.5")
        try await repo.removeTrack(playlistId: a.id!, trackId: 1)

        let afterRemove = try await repo.fetchPlaylists(forTrackId: 1)
        #expect(afterRemove.isEmpty)

        try await repo.addTrack(playlistId: a.id!, trackId: 1, position: "0.5")

        let afterReAdd = try await repo.fetchPlaylists(forTrackId: 1)
        #expect(afterReAdd.map(\.name) == ["Alpha"])
    }

    /// W3-PL (DEC-003): the sidebar's manual order, not pinned-then-name; `is_pinned` is ignored.
    @Test func fetchPlaylists_ordersLikeTheSidebar() async throws {
        let (db, repo) = try makeRepo()
        let a = try await repo.create(name: "Alpha")
        let z = try await repo.create(name: "Zulu")

        try await seedTrack(in: db, id: 1)
        try await repo.addTrack(playlistId: a.id!, trackId: 1, position: "0.5")
        try await repo.addTrack(playlistId: z.id!, trackId: 1, position: "0.5")

        // Zulu first in the user's order; Alpha pinned, which no longer means anything.
        try await db.write { db in
            try db.execute(sql: "UPDATE playlists SET position = 'a1' WHERE id = ?", arguments: [z.id!])
            try db.execute(sql: "UPDATE playlists SET position = 'a2', is_pinned = 1 WHERE id = ?", arguments: [a.id!])
        }

        let result = try await repo.fetchPlaylists(forTrackId: 1)
        #expect(result.map(\.name) == ["Zulu", "Alpha"])
        #expect(try await repo.fetchAll().map(\.name) == ["Zulu", "Alpha"])
    }
}
