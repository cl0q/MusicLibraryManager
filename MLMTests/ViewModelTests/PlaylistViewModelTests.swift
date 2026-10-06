import Testing
import Foundation
import GRDB
@testable import MLM

/// Playlist provenance and download-health buckets. The grid's view model (`PlaylistViewModel`,
/// with its pin limit and cover-drop banner) is gone (W3-PL): the grid reads `SidebarModel`
/// and `PlaylistGridRules` (`PlaylistPresentationTests`); a refused cover says so on the card.
@MainActor
struct PlaylistViewModelTests {

    // MARK: - Helpers

    private func makeRepositories() throws -> (DatabaseQueue, PlaylistRepository, SidebarModel) {
        let db = try DatabaseManager.inMemory()
        let sidebar = SidebarModel(defaults: UserDefaults(suiteName: "PlaylistViewModelTests-\(UUID().uuidString)")!)
        return (db, PlaylistRepository(database: db), sidebar)
    }

    // MARK: - Source provenance (the grid resolves it from one sources-table snapshot)

    @Test func loadPlaylists_resolvesSourceFromSourcesTable() async throws {
        let (db, repo, sidebar) = try makeRepositories()
        let sourceRepo = SourceRepository(database: db)
        let source = try await sourceRepo.upsert(name: "youtube", userId: "local")
        let playlist = try await repo.findOrCreateSourcePlaylist(
            name: "Spotify favorites",
            sourceId: try #require(source.id),
            externalId: "youtube-playlist-1"
        )

        await sidebar.reloadSources(sourceRepo)
        await sidebar.reloadPlaylists(repo)

        let name = try #require(playlist.sourceId.flatMap { sidebar.sourceNames[$0] })
        #expect(PlaylistSourceIdentity(sourceName: name) == .youtube)
        #expect(PlaylistSourceIdentity(sourceName: name).displayName == "YouTube")
        #expect(sidebar.hasLoadedPlaylists)
    }

    @Test func loadPlaylists_keepsLocalPlaylistWithoutProvenance() async throws {
        let (_, repo, sidebar) = try makeRepositories()
        let playlist = try await repo.create(name: "Local favorites")
        await sidebar.reloadPlaylists(repo)
        #expect(sidebar.playlists.first { $0.id == playlist.id }?.sourceId == nil)
    }

    @Test func playlistSourceIdentity_mapsKnownSourceNames() {
        func source(named name: String) -> Source {
            Source(id: nil, name: name, userId: "test", enabled: 1)
        }

        #expect(source(named: "SoundCloud").playlistSourceIdentity == .soundcloud)
        #expect(source(named: "spotify").playlistSourceIdentity == .spotify)
        #expect(source(named: "YouTube").playlistSourceIdentity == .youtube)
        #expect(source(named: "Apple Music").playlistSourceIdentity == .appleMusic)
        #expect(source(named: "YouTube").sourceType == .unknown)
    }

    @Test func playlistSourceIdentity_pinsOnlyDirectDownloadSources() {
        #expect(PlaylistSourceIdentity.soundcloud.downloadPin == .soundcloud)
        #expect(PlaylistSourceIdentity.youtube.downloadPin == .youtube)
        #expect(PlaylistSourceIdentity.spotify.downloadPin == .auto)
        #expect(PlaylistSourceIdentity.appleMusic.downloadPin == .auto)
        #expect(PlaylistSourceIdentity.other("Local files").downloadPin == .auto)
    }

    @Test func downloadStatus_usesExclusiveAvailabilityBuckets() async throws {
        let (db, repo, _) = try makeRepositories()
        let playlist = try await repo.create(name: "Download health")
        let playlistID = try #require(playlist.id)

        let trackIDs = try await db.write { db -> [Int64] in
            var local = Track(
                artist: "Artist",
                album: "Album",
                title: "Local",
                format: "m4a",
                originalPath: "local://track"
            )
            local.organizedPath = "Artist/Album/Local.m4a"
            try local.insert(db)

            var downloading = Track(
                artist: "Artist",
                album: "Album",
                title: "Downloading",
                format: "youtube",
                originalPath: "youtube://track"
            )
            downloading.downloadStatus = "downloading"
            try downloading.insert(db)

            var failed = Track(
                artist: "Artist",
                album: "Album",
                title: "Failed",
                format: "youtube",
                originalPath: "youtube://failed"
            )
            try failed.setDownloadFailureRecord(
                TrackDownloadFailure(reason: "Video unavailable", date: .now, attempts: 2)
            )
            try failed.insert(db)

            var retrying = Track(
                artist: "Artist",
                album: "Album",
                title: "Retrying",
                format: "youtube",
                originalPath: "youtube://retrying"
            )
            retrying.downloadStatus = "queued"
            try retrying.setDownloadFailureRecord(
                TrackDownloadFailure(reason: "Network error", date: .now, attempts: 2)
            )
            try retrying.insert(db)

            var remote = Track(
                artist: "Artist",
                album: "Album",
                title: "Remote",
                format: "youtube",
                originalPath: "youtube://remote"
            )
            try remote.insert(db)

            guard let localID = local.id,
                  let downloadingID = downloading.id,
                  let failedID = failed.id,
                  let retryingID = retrying.id,
                  let remoteID = remote.id else {
                throw NSError(domain: "PlaylistViewModelTests", code: 1)
            }
            return [localID, downloadingID, failedID, retryingID, remoteID]
        }

        try await repo.addTracks(
            playlistId: playlistID,
            trackIds: trackIDs,
            startPosition: "a0"
        )

        let status = try #require(
            try await repo.fetchDownloadStatuses().first { $0.playlistID == playlistID }
        )
        #expect(status.totalTracks == 5)
        #expect(status.localTracks == 1)
        #expect(status.downloadingTracks == 2)
        #expect(status.failedTracks == 1)
        #expect(status.notDownloadedTracks == 1)
        #expect(status.missingTracks == 1)
        #expect(
            status.localTracks
                + status.downloadingTracks
                + status.failedTracks
                + status.notDownloadedTracks
                == status.totalTracks
        )
        #expect(status.isImporting)
        #expect(status.isIncomplete)
    }

}
