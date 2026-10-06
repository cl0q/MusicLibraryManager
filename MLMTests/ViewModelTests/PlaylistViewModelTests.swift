import Testing
import Foundation
import GRDB
@testable import MLM

/// Tests for `PlaylistViewModel`'s 8-pin pre-check, transient hint state,
/// cover-drop-error state, and the notification-post side effect on togglePin.
///
/// Phase 36, Plan 03. The view-model layer is pure Swift state on top of
/// `PlaylistRepository`; we use an in-memory GRDB queue so the tests stay
/// hermetic. Filesystem-touching cover operations remain in the service
/// suite (`PlaylistCoverServiceTests`).
@MainActor
struct PlaylistViewModelTests {

    // MARK: - Helpers

    private func makeViewModel() throws -> (DatabaseQueue, PlaylistRepository, PlaylistViewModel) {
        let db = try DatabaseManager.inMemory()
        let repo = PlaylistRepository(database: db)
        let sourceRepo = SourceRepository(database: db)
        let vm = PlaylistViewModel(
            playlistRepository: repo,
            sourceRepository: sourceRepo
        )
        return (db, repo, vm)
    }

    // MARK: - Transient hint state surface
    // The 8-pin limit and its tests are gone with pinning (DEC-003, S-PL-BANNER-PINLIMIT removed).

    @Test func coverDropErrorMessage_startsNil() throws {
        let (_, _, vm) = try makeViewModel()
        #expect(vm.coverDropErrorMessage == nil)
    }

    // MARK: - flagCoverDropRejected

    @Test func flagCoverDropRejected_setsBannerCopy() async throws {
        let (_, _, vm) = try makeViewModel()
        vm.flagCoverDropRejected()
        #expect(vm.coverDropErrorMessage == "Couldn't read that image. Try a PNG or JPEG file.")
    }

    // MARK: - Source provenance

    @Test func loadPlaylists_resolvesSourceFromSourcesTable() async throws {
        let (db, repo, vm) = try makeViewModel()
        let sourceRepo = SourceRepository(database: db)
        let source = try await sourceRepo.upsert(name: "youtube", userId: "local")
        let playlist = try await repo.findOrCreateSourcePlaylist(
            name: "Spotify favorites",
            sourceId: try #require(source.id),
            externalId: "youtube-playlist-1"
        )

        await vm.loadPlaylists()

        #expect(vm.source(for: playlist)?.playlistSourceIdentity == .youtube)
        #expect(vm.source(for: playlist)?.playlistSourceIdentity.displayName == "YouTube")
    }

    @Test func loadPlaylists_keepsLocalPlaylistWithoutProvenance() async throws {
        let (_, repo, vm) = try makeViewModel()
        let playlist = try await repo.create(name: "Local favorites")

        await vm.loadPlaylists()

        #expect(vm.source(for: playlist) == nil)
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
        let (db, repo, _) = try makeViewModel()
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
