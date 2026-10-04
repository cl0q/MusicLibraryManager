import Testing
import Foundation
import GRDB
@testable import MLM

/// Tests for the three-predicate filter pipeline in `PlaylistViewModel`
/// (name search × source × incomplete) and the `availableSourceIdentities`
/// derivation. Covers UI-012.
@MainActor
struct PlaylistFilterTests {

    // MARK: - Helpers

    private func makeViewModel() throws -> (DatabaseQueue, PlaylistRepository, SourceRepository, PlaylistViewModel) {
        let db = try DatabaseManager.inMemory()
        let playlistRepo = PlaylistRepository(database: db)
        let sourceRepo = SourceRepository(database: db)
        let vm = PlaylistViewModel(playlistRepository: playlistRepo, sourceRepository: sourceRepo)
        return (db, playlistRepo, sourceRepo, vm)
    }

    /// Seed a linked playlist via the repository + source upsert, then load the VM.
    private func seedLinkedPlaylist(
        name: String,
        sourceName: String,
        db: DatabaseQueue,
        playlistRepo: PlaylistRepository,
        sourceRepo: SourceRepository,
        vm: PlaylistViewModel
    ) async throws -> Playlist {
        let source = try await sourceRepo.upsert(name: sourceName, userId: "test")
        let playlist = try await playlistRepo.create(name: name)
        try await playlistRepo.updateSourceLink(
            id: playlist.id!,
            sourceId: source.id,
            externalId: "\(sourceName)-\(name)"
        )
        await vm.loadPlaylists()
        let refreshed = try await playlistRepo.fetch(id: playlist.id!)
        return refreshed!
    }

    /// Seed a track with a download failure into a playlist so fetchDownloadStatuses
    /// reports it as incomplete (failedTracks > 0).
    private func seedFailedTrack(
        in playlistID: Int64,
        db: DatabaseQueue
    ) async throws {
        try await db.write { db in
            var track = Track(
                artist: "A",
                album: "B",
                title: "Failed Track \(playlistID)",
                format: "youtube",
                originalPath: "youtube://failed-\(playlistID)"
            )
            try track.setDownloadFailureRecord(
                TrackDownloadFailure(reason: "Unavailable", date: .now, attempts: 1)
            )
            try track.insert(db)

            var entry = PlaylistTrack(
                id: nil,
                playlistId: playlistID,
                trackId: track.id!,
                position: "a0",
                addedAt: nil
            )
            try entry.insert(db)
        }
    }

    // MARK: - Name search regression

    @Test func nameSearch_filtersByName() async throws {
        let (_, repo, _, vm) = try makeViewModel()
        _ = try await repo.create(name: "Alpha")
        _ = try await repo.create(name: "Beta")
        _ = try await repo.create(name: "Gamma")
        await vm.loadPlaylists()

        vm.searchQuery = "alp"
        #expect(vm.displayedPlaylists.count == 1)
        #expect(vm.displayedPlaylists.first?.name == "Alpha")
    }

    // MARK: - Source filter

    @Test func sourceFilter_local_keepsOnlyUnlinked() async throws {
        let (db, playlistRepo, sourceRepo, vm) = try makeViewModel()
        _ = try await playlistRepo.create(name: "Local One")
        _ = try await playlistRepo.create(name: "Local Two")
        _ = try await seedLinkedPlaylist(
            name: "Spotify Mix", sourceName: "spotify",
            db: db, playlistRepo: playlistRepo, sourceRepo: sourceRepo, vm: vm
        )
        await vm.loadPlaylists()

        vm.sourceFilter = .local
        #expect(vm.displayedPlaylists.count == 2)
        #expect(vm.displayedPlaylists.allSatisfy { vm.source(for: $0) == nil })
    }

    @Test func sourceFilter_identity_keepsOnlyMatching() async throws {
        let (db, playlistRepo, sourceRepo, vm) = try makeViewModel()
        _ = try await seedLinkedPlaylist(
            name: "Spotify Mix", sourceName: "spotify",
            db: db, playlistRepo: playlistRepo, sourceRepo: sourceRepo, vm: vm
        )
        _ = try await seedLinkedPlaylist(
            name: "YT Favorites", sourceName: "youtube",
            db: db, playlistRepo: playlistRepo, sourceRepo: sourceRepo, vm: vm
        )
        _ = try await playlistRepo.create(name: "Local")
        await vm.loadPlaylists()

        vm.sourceFilter = .identity(.spotify)
        #expect(vm.displayedPlaylists.count == 1)
        #expect(vm.displayedPlaylists.first?.name == "Spotify Mix")

        vm.sourceFilter = .identity(.youtube)
        #expect(vm.displayedPlaylists.count == 1)
        #expect(vm.displayedPlaylists.first?.name == "YT Favorites")
    }

    // MARK: - Combined filter

    @Test func combinedFilter_searchAndSource_intersects() async throws {
        let (db, playlistRepo, sourceRepo, vm) = try makeViewModel()
        _ = try await seedLinkedPlaylist(
            name: "Spotify Chill", sourceName: "spotify",
            db: db, playlistRepo: playlistRepo, sourceRepo: sourceRepo, vm: vm
        )
        _ = try await seedLinkedPlaylist(
            name: "Spotify Workout", sourceName: "spotify",
            db: db, playlistRepo: playlistRepo, sourceRepo: sourceRepo, vm: vm
        )
        _ = try await seedLinkedPlaylist(
            name: "YouTube Chill", sourceName: "youtube",
            db: db, playlistRepo: playlistRepo, sourceRepo: sourceRepo, vm: vm
        )
        await vm.loadPlaylists()

        vm.searchQuery = "chill"
        vm.sourceFilter = .identity(.spotify)
        #expect(vm.displayedPlaylists.count == 1)
        #expect(vm.displayedPlaylists.first?.name == "Spotify Chill")
    }

    // MARK: - availableSourceIdentities

    @Test func availableSourceIdentities_reflectsPresentSources() async throws {
        let (db, playlistRepo, sourceRepo, vm) = try makeViewModel()
        _ = try await seedLinkedPlaylist(
            name: "A", sourceName: "youtube",
            db: db, playlistRepo: playlistRepo, sourceRepo: sourceRepo, vm: vm
        )
        _ = try await seedLinkedPlaylist(
            name: "B", sourceName: "spotify",
            db: db, playlistRepo: playlistRepo, sourceRepo: sourceRepo, vm: vm
        )
        _ = try await seedLinkedPlaylist(
            name: "C", sourceName: "spotify",
            db: db, playlistRepo: playlistRepo, sourceRepo: sourceRepo, vm: vm
        )
        _ = try await playlistRepo.create(name: "Local")
        await vm.loadPlaylists()

        let identities = vm.availableSourceIdentities
        #expect(identities.count == 2)
        // Sorted by displayName: Spotify < YouTube
        #expect(identities[0] == .spotify)
        #expect(identities[1] == .youtube)
    }

    // MARK: - Incomplete filter

    @Test func incompleteOnly_filtersOnIsIncomplete() async throws {
        let (db, playlistRepo, _, vm) = try makeViewModel()
        _ = try await playlistRepo.create(name: "No Tracks")
        let withFailure = try await playlistRepo.create(name: "Has Failures")
        await vm.loadPlaylists()

        try await seedFailedTrack(in: withFailure.id!, db: db)
        // Reload to pick up the new download status
        await vm.loadPlaylists()

        vm.incompleteOnly = true
        #expect(vm.displayedPlaylists.count == 1)
        #expect(vm.displayedPlaylists.first?.name == "Has Failures")
    }

    // MARK: - Empty-result vs empty-collection

    @Test func emptyResultVsEmptyCollection_displayedEmptyWhilePlaylistsNonEmpty() async throws {
        let (_, playlistRepo, _, vm) = try makeViewModel()
        _ = try await playlistRepo.create(name: "Alpha")
        await vm.loadPlaylists()

        #expect(vm.playlists.isEmpty == false)
        vm.searchQuery = "zzz_nonexistent"
        #expect(vm.displayedPlaylists.isEmpty)
        #expect(vm.playlists.count == 1)
    }
}
