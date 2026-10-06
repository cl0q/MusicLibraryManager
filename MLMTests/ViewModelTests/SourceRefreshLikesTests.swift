import Foundation
import GRDB
import Testing
@testable import MLM

/// `Refresh from Sources` also appends new likes to a Liked playlist that exists (W5-F2, the
/// `// LIKES:` marker): add-only, never creating a Liked playlist, never removing a row, only for
/// a source whose likes can be read. No network: the likes come from a fake.
@Suite("SourceRefreshLikesTests")
@MainActor
struct SourceRefreshLikesTests {
    private func track(_ db: DatabaseQueue, _ title: String) async throws -> Int64 {
        var t = Track(artist: "A", album: "", title: title, format: "mp3", originalPath: "/m/\(title).mp3")
        t.organizedPath = "A/\(title).mp3"
        return try await TrackRepository(database: db).insert(t).id!
    }

    private func refresher(_ db: DatabaseQueue, likes: (@MainActor (Source) async throws -> [Int64])?,
                           listed: @escaping @MainActor (Playlist, Source) async throws -> [RemotePlaylistTrack] = { _, _ in [] })
        -> LinkedPlaylistsRefresher {
        LinkedPlaylistsRefresher(database: db, listTracks: listed, listLikes: likes, notificationCenter: NotificationCenter())
    }

    @Test func newLikesAreAppendedAfterTheRowsThatAreThereAndNothingIsRemoved() async throws {
        let db = try DatabaseManager.inMemory()
        let playlists = PlaylistRepository(database: db)
        let source = try await SourceRepository(database: db).upsert(name: "soundcloud", userId: "me")
        let liked = try await playlists.findOrCreateLikedPlaylist(name: "Liked from SoundCloud", sourceId: source.id!, externalId: nil)
        let one = try await track(db, "One"), two = try await track(db, "Two"), three = try await track(db, "Three")
        let mine = try await track(db, "Hand-added")
        try await playlists.replaceTrackList(playlistId: liked.id!, trackIds: [two, mine])
        let before = try await playlists.fetchTracks(playlistId: liked.id!).map(\.id)

        // The source lists its likes newest first; Two is already there, Mine is no longer liked.
        let summary = try await refresher(db, likes: { _ in [three, two, one] }).refresh(.soundcloud)

        let after = try await playlists.fetchTracks(playlistId: liked.id!).map(\.id)
        #expect(Array(after.prefix(before.count)) == before, "rows that were there keep their place")
        #expect(after == [two, mine, three, one].map { Optional($0) }, "new likes follow, in the source’s order")
        #expect(after.contains(mine), "nothing is removed (IMP-042)")
        #expect(summary.newTracks == 2)
        #expect(summary.playlistsUpdated == 1)
    }

    @Test func aSourceWithoutALikedPlaylistGetsNoneCreated() async throws {
        let db = try DatabaseManager.inMemory()
        _ = try await SourceRepository(database: db).upsert(name: "soundcloud", userId: "me")
        let one = try await track(db, "One")
        var asked = 0
        let before = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playlists") }
        let summary = try await refresher(db, likes: { _ in asked += 1; return [one] }).refresh(.soundcloud)
        #expect(asked == 0, "the likes aren’t even read")
        #expect(summary == SourceRefreshSummary())
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playlists") } == before)
    }

    @Test func nothingNewIsNoUpdateAndAFailingReadIsNamed() async throws {
        let db = try DatabaseManager.inMemory()
        let playlists = PlaylistRepository(database: db)
        let source = try await SourceRepository(database: db).upsert(name: "soundcloud", userId: "me")
        let liked = try await playlists.findOrCreateLikedPlaylist(name: "Liked from SoundCloud", sourceId: source.id!, externalId: nil)
        let one = try await track(db, "One")
        try await playlists.replaceTrackList(playlistId: liked.id!, trackIds: [one])

        let same = try await refresher(db, likes: { _ in [one] }).refresh(.soundcloud)
        #expect(same.newTracks == 0 && same.playlistsUpdated == 0)

        let failed = try await refresher(db, likes: { _ in throw CocoaError(.fileReadUnknown) }).refresh(.soundcloud)
        #expect(failed.failedPlaylists == ["Liked from SoundCloud"])
        #expect(try await playlists.fetchTracks(playlistId: liked.id!).count == 1)
    }

    @Test func aRejectedSignInStopsTheRefreshForTheSource() async throws {
        let db = try DatabaseManager.inMemory()
        let source = try await SourceRepository(database: db).upsert(name: "soundcloud", userId: "me")
        _ = try await PlaylistRepository(database: db).findOrCreateLikedPlaylist(name: "Liked from SoundCloud", sourceId: source.id!, externalId: nil)
        await #expect(throws: SoundCloudClient.SoundCloudError.self) {
            _ = try await refresher(db, likes: { _ in throw SoundCloudClient.SoundCloudError.tokenExpired }).refresh(.soundcloud)
        }
    }

    @Test func spotifyLikesAreNotReadAndLinkedPlaylistsStillRefresh() async throws {
        let db = try DatabaseManager.inMemory()
        let source = try await SourceRepository(database: db).upsert(name: "spotify", userId: "me")
        _ = try await PlaylistRepository(database: db).findOrCreateLikedPlaylist(name: "Liked from Spotify", sourceId: source.id!, externalId: nil)
        var asked = 0
        let summary = try await refresher(db, likes: { _ in asked += 1; return [] }).refresh(.spotify)
        #expect(asked == 0, "only SoundCloud likes can be read")
        #expect(summary == SourceRefreshSummary())
    }
}
