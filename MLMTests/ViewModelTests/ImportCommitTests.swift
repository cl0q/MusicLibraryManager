import Foundation
import GRDB
import Testing
@testable import MLM

/// W3-ADD review H1 / H4: Refresh from Sources is add-only on linked playlists; the import
/// matches local tracks by artist + title + duration and commits in one transaction.
@Suite("Import commit and Refresh from Sources")
@MainActor
struct ImportCommitTests {
    private func remote(_ id: String, title: String? = nil, artist: String = "Artist", duration: Int? = 200,
                        album: String = "SoundCloud", source: LinkSource = .soundcloud) -> RemotePlaylistTrack {
        RemotePlaylistTrack(externalID: id, title: title ?? "Track \(id)", artist: artist, album: album,
                            durationSeconds: duration, format: source.storedName,
                            originalPath: "https://example.test/\(source.storedName)/\(id)")
    }

    private func preview(_ id: String, _ title: String, _ tracks: [RemotePlaylistTrack], source: LinkSource = .soundcloud) -> RemotePlaylistPreview {
        RemotePlaylistPreview(sourceName: source.rawValue, externalID: id, title: title, tracks: tracks)
    }

    private func importer(_ db: DatabaseQueue) -> PlaylistImporter {
        PlaylistImporter(database: db, downloads: RecordingPlaylistDownloads(), notificationCenter: NotificationCenter())
    }

    private func count(_ db: DatabaseQueue, _ sql: String) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }

    // MARK: H4

    @Test func aTrackOwnedAsALocalFileShowsInLibraryAndIsNotInsertedAgain() async throws {
        let db = try DatabaseManager.inMemory()
        var local = Track(artist: "Bicep", album: "Isles", title: "Glue", format: "flac", originalPath: "/Music/Bicep/Glue.flac")
        local.organizedPath = "Bicep/Isles/Glue.flac"
        local.duration = 269
        let owned = try await TrackRepository(database: db).insert(local)

        let rows = [remote("sc-1", title: "glue", artist: " BICEP ", duration: 270), remote("sc-2", duration: 100)]
        let matches = try await ImportLibraryQueries(database: db).matches(for: rows, source: .soundcloud)
        #expect(matches["sc-1"] == .downloaded(trackID: owned.id!))
        #expect(matches["sc-2"] == .new)
        // ± 2 s only.
        let far = try await ImportLibraryQueries(database: db).matches(for: [remote("sc-3", title: "Glue", artist: "Bicep", duration: 275)],
                                                                      source: .soundcloud)
        #expect(far["sc-3"] == .new)

        let source = try await SourceRepository(database: db).upsert(name: "soundcloud", userId: "me")
        let outcome = try await importer(db).run(PlaylistImportRequest(preview: preview("set", "Set", rows), tracks: rows,
                                                                       source: .soundcloud, downloadNow: false),
                                                 sourceRowID: { source.id! })
        #expect(outcome.addedToLibrary == 1)
        #expect(outcome.alreadyInLibrary == 1)
        #expect(try count(db, "SELECT COUNT(*) FROM tracks") == 2)
    }

    @Test func concurrentImportsOfOverlappingPlaylistsNeverDuplicateATrack() async throws {
        let db = try DatabaseManager.inMemory()
        let source = try await SourceRepository(database: db).upsert(name: "soundcloud", userId: "me")
        let a = ["1", "2", "3"].map { remote($0) }
        let b = ["2", "3", "4"].map { remote($0) }
        let first = importer(db)
        let second = importer(db)
        async let one = first.run(PlaylistImportRequest(preview: preview("a", "A", a), tracks: a, source: .soundcloud, downloadNow: false),
                                  sourceRowID: { source.id! })
        async let two = second.run(PlaylistImportRequest(preview: preview("b", "B", b), tracks: b, source: .soundcloud, downloadNow: false),
                                   sourceRowID: { source.id! })
        let (x, y) = try await (one, two)

        #expect(try count(db, "SELECT COUNT(*) FROM tracks") == 4)
        #expect(try count(db, "SELECT COUNT(*) FROM track_sources") == 4)
        #expect(x.addedToLibrary + y.addedToLibrary == 4)
        let playlists = PlaylistRepository(database: db)
        #expect(try await playlists.fetchTracks(playlistId: x.playlistID).count == 3)
        #expect(try await playlists.fetchTracks(playlistId: y.playlistID).count == 3)
    }

    @Test func aFailedCommitLeavesNothingHalfDone() async throws {
        let db = try DatabaseManager.inMemory()
        let source = try await SourceRepository(database: db).upsert(name: "soundcloud", userId: "me")
        let rows = ["1", "2"].map { remote($0) }
        await #expect(throws: PlaylistImportError.playlistGone) {
            _ = try await importer(db).run(PlaylistImportRequest(preview: preview("a", "A", rows), tracks: rows, source: .soundcloud,
                                                                 target: .existing(id: 999, name: "Gone"), downloadNow: false),
                                           sourceRowID: { source.id! })
        }
        #expect(try count(db, "SELECT COUNT(*) FROM tracks") == 0, "the whole commit is one transaction")
        #expect(PlaylistImportError.libraryNotWritable.plainCause == "the library database couldn’t be updated")
    }

    @Test func aRealAlbumCalledUnknownIsKept() {
        #expect(PlaylistImporter.album("Unknown") == "Unknown")
        #expect(PlaylistImporter.album("SoundCloud") == "")
        #expect(PlaylistImporter.album(" unknown album ") == "")
    }

    // MARK: H1

    @Test func refreshFromSourcesOnlyAddsToLinkedPlaylistsAndTouchesNothingElse() async throws {
        let db = try DatabaseManager.inMemory()
        let sources = SourceRepository(database: db)
        let playlists = PlaylistRepository(database: db)
        let soundcloud = try await sources.upsert(name: "soundcloud", userId: "me")
        let youtube = try await sources.upsert(name: "youtube", userId: "local")

        // A linked SoundCloud set imported as `First 1`, plus a track the user added by hand.
        let set = ["1", "2", "3"].map { remote($0) }
        let imported = try await importer(db).run(
            PlaylistImportRequest(preview: preview("set-1", "Late night", set), tracks: [set[0]], source: .soundcloud, downloadNow: false),
            sourceRowID: { soundcloud.id! })
        var mine = Track(artist: "Me", album: "Edits", title: "Hand-added", format: "flac", originalPath: "/Music/mine.flac")
        mine.organizedPath = "Me/Edits/Hand-added.flac"
        let handAdded = try await TrackRepository(database: db).insert(mine)
        try await playlists.appendTracks(playlistId: imported.playlistID, trackIds: [handAdded.id!])

        // A YouTube playlist that shares a SoundCloud set's name.
        let chillTracks = [remote("y1", source: .youtube)]
        let chill = try await importer(db).run(
            PlaylistImportRequest(preview: preview("https://www.youtube.com/playlist?list=PLchill", "Chill", chillTracks, source: .youtube),
                                  tracks: chillTracks, source: .youtube, downloadNow: false),
            sourceRowID: { youtube.id! })
        let playlistsBefore = try count(db, "SELECT COUNT(*) FROM playlists")

        var asked: [String] = []
        let refresher = LinkedPlaylistsRefresher(database: db, listTracks: { playlist, _ in
            asked.append(playlist.name)
            return set + [self.remote("chill-set-track")]
        }, notificationCenter: NotificationCenter())
        let summary = try await refresher.refresh(.soundcloud)

        #expect(asked == ["Late night"], "only playlists linked to this source")
        #expect(summary.newTracks == 3)
        #expect(summary.playlistsUpdated == 1)
        let titles = try await playlists.fetchTracks(playlistId: imported.playlistID).map(\.title)
        #expect(titles == ["Track 1", "Hand-added", "Track 2", "Track 3", "Track chill-set-track"],
                "add-only: the hand-added track and the order stay")
        #expect(try count(db, "SELECT COUNT(*) FROM playlists") == playlistsBefore, "no playlist is created")
        let chillRow = try #require(try await playlists.fetch(id: chill.playlistID))
        #expect(chillRow.sourceId == youtube.id)
        #expect(chillRow.externalId == "https://www.youtube.com/playlist?list=PLchill")
        #expect(try await playlists.fetchTracks(playlistId: chill.playlistID).count == 1)
        #expect(try count(db, "SELECT COUNT(*) FROM tracks WHERE album != '' AND id != \(handAdded.id!)") == 0,
                "no album is written")
    }
}
