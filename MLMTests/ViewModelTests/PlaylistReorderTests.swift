import Testing
import GRDB
@testable import MLM

@Suite("PlaylistReorderTests")
struct PlaylistReorderTests {

    // MARK: - Helpers

    private func seedTrack(in db: DatabaseQueue, id: Int64) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, date_added)
                VALUES (?, 'A', 'A', 'Album', 'Track \(id)', 'mp3', '/tmp/t\(id).mp3', '2025-01-01T00:00:00Z')
            """, arguments: [id])
        }
    }

    private func makeHarness() async throws -> (DatabaseQueue, PlaylistRepository, TrackRepository, SourceRepository, Playlist) {
        let db = try DatabaseManager.inMemory()
        let plRepo = PlaylistRepository(database: db)
        let trRepo = TrackRepository(database: db)
        let srRepo = SourceRepository(database: db)
        let playlist = try await plRepo.create(name: "Test")
        return (db, plRepo, trRepo, srRepo, playlist)
    }

    private func makeVM(
        playlist: Playlist,
        playlistRepo: PlaylistRepository,
        trackRepo: TrackRepository,
        sourceRepo: SourceRepository
    ) -> PlaylistDetailViewModel {
        PlaylistDetailViewModel(
            playlist: playlist,
            playlistRepository: playlistRepo,
            trackRepository: trackRepo,
            sourceRepository: sourceRepo
        )
    }

    /// Fetch raw position strings in SQL ORDER BY order to verify persistence.
    private func fetchPositions(playlistId: Int64, from db: DatabaseQueue) async throws -> [(trackId: Int64, position: String)] {
        try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT track_id, position FROM playlist_tracks
                WHERE playlist_id = ?
                ORDER BY position, added_at ASC
            """, arguments: [playlistId])
            return rows.map { ($0["track_id"] as Int64, $0["position"] as String) }
        }
    }

    // MARK: - Tests

    @Test func moveLastTrackToIndex0_persistsNewOrder() async throws {
        let (db, plRepo, trRepo, srRepo, playlist) = try await makeHarness()
        let pid = playlist.id!

        // Seed 5 tracks with strictly ascending positions.
        for id: Int64 in [1, 2, 3, 4, 5] {
            try await seedTrack(in: db, id: id)
            let pos = "a\(id)"
            try await plRepo.addTrack(playlistId: pid, trackId: id, position: pos)
        }

        let vm = makeVM(playlist: playlist, playlistRepo: plRepo, trackRepo: trRepo, sourceRepo: srRepo)
        await vm.loadTracks()
        #expect(vm.tracks.map(\.id) == [1, 2, 3, 4, 5])

        // Move track 5 (last) to index 0.
        await vm.placeTracks([5], at: 0)

        // In-memory order.
        #expect(vm.tracks.map(\.id) == [5, 1, 2, 3, 4])

        // Persisted order.
        let persisted = try await plRepo.fetchTracks(playlistId: pid)
        #expect(persisted.map(\.id) == [5, 1, 2, 3, 4])

        // Positions are strictly ascending.
        let positions = try await fetchPositions(playlistId: pid, from: db)
        let posStrings = positions.map(\.position)
        #expect(posStrings == posStrings.sorted())
    }

    @Test func moveFirstTrackToEnd() async throws {
        let (db, plRepo, trRepo, srRepo, playlist) = try await makeHarness()
        let pid = playlist.id!

        for id: Int64 in [1, 2, 3, 4, 5] {
            try await seedTrack(in: db, id: id)
            try await plRepo.addTrack(playlistId: pid, trackId: id, position: "a\(id)")
        }

        let vm = makeVM(playlist: playlist, playlistRepo: plRepo, trackRepo: trRepo, sourceRepo: srRepo)
        await vm.loadTracks()

        // Move track 1 to the end (insertionIndex == tracks.count).
        await vm.placeTracks([1], at: 5)

        #expect(vm.tracks.map(\.id) == [2, 3, 4, 5, 1])

        let persisted = try await plRepo.fetchTracks(playlistId: pid)
        #expect(persisted.map(\.id) == [2, 3, 4, 5, 1])
    }

    @Test func moveMiddleTrackToAnotherMiddleSlot() async throws {
        let (db, plRepo, trRepo, srRepo, playlist) = try await makeHarness()
        let pid = playlist.id!

        for id: Int64 in [1, 2, 3, 4, 5] {
            try await seedTrack(in: db, id: id)
            try await plRepo.addTrack(playlistId: pid, trackId: id, position: "a\(id)")
        }

        let vm = makeVM(playlist: playlist, playlistRepo: plRepo, trackRepo: trRepo, sourceRepo: srRepo)
        await vm.loadTracks()

        // Move track 2 (index 1) to index 3 (before track 4).
        await vm.placeTracks([2], at: 3)

        #expect(vm.tracks.map(\.id) == [1, 3, 2, 4, 5])

        let persisted = try await plRepo.fetchTracks(playlistId: pid)
        #expect(persisted.map(\.id) == [1, 3, 2, 4, 5])
    }

    @Test func moveToOwnSlotIsNoOp() async throws {
        let (db, plRepo, trRepo, srRepo, playlist) = try await makeHarness()
        let pid = playlist.id!

        for id: Int64 in [1, 2, 3] {
            try await seedTrack(in: db, id: id)
            try await plRepo.addTrack(playlistId: pid, trackId: id, position: "a\(id)")
        }

        let vm = makeVM(playlist: playlist, playlistRepo: plRepo, trackRepo: trRepo, sourceRepo: srRepo)
        await vm.loadTracks()

        let originalIDs = vm.tracks.map(\.id)

        // Move track 2 (index 1) to index 1 — same slot.
        await vm.placeTracks([2], at: 1)

        #expect(vm.tracks.map(\.id) == originalIDs)
    }

    @Test func externalInsert_appearsAtIndex_andPersists() async throws {
        let (db, plRepo, trRepo, srRepo, playlist) = try await makeHarness()
        let pid = playlist.id!

        for id: Int64 in [1, 2, 3, 4] {
            try await seedTrack(in: db, id: id)
            try await plRepo.addTrack(playlistId: pid, trackId: id, position: "a\(id)")
        }
        // Track 999 exists in the library but NOT in the playlist.
        try await seedTrack(in: db, id: 999)

        let vm = makeVM(playlist: playlist, playlistRepo: plRepo, trackRepo: trRepo, sourceRepo: srRepo)
        await vm.loadTracks()
        #expect(vm.tracks.count == 4)

        // Insert track 999 at index 2.
        await vm.placeTracks([999], at: 2)

        #expect(vm.tracks.count == 5)
        #expect(vm.tracks[2].id == 999)

        // Persisted.
        let persisted = try await plRepo.fetchTracks(playlistId: pid)
        #expect(persisted.count == 5)
        #expect(persisted[2].id == 999)

        // A playlist_tracks row exists for 999.
        let positions = try await fetchPositions(playlistId: pid, from: db)
        #expect(positions.contains { $0.trackId == 999 })
    }

    @Test func multiTrackMove_preservesDragOrder() async throws {
        let (db, plRepo, trRepo, srRepo, playlist) = try await makeHarness()
        let pid = playlist.id!

        for id: Int64 in [1, 2, 3, 4, 5] {
            try await seedTrack(in: db, id: id)
            try await plRepo.addTrack(playlistId: pid, trackId: id, position: "a\(id)")
        }

        let vm = makeVM(playlist: playlist, playlistRepo: plRepo, trackRepo: trRepo, sourceRepo: srRepo)
        await vm.loadTracks()

        // Drag tracks [4, 2] (in that order) to index 0.
        await vm.placeTracks([4, 2], at: 0)

        // The dragged group should appear in drag order at the front.
        #expect(vm.tracks.map(\.id) == [4, 2, 1, 3, 5])

        let persisted = try await plRepo.fetchTracks(playlistId: pid)
        #expect(persisted.map(\.id) == [4, 2, 1, 3, 5])
    }

    @Test func positionsStayStrictlyAscending_afterReorder() async throws {
        let (db, plRepo, trRepo, srRepo, playlist) = try await makeHarness()
        let pid = playlist.id!

        for id: Int64 in [1, 2, 3, 4, 5] {
            try await seedTrack(in: db, id: id)
            try await plRepo.addTrack(playlistId: pid, trackId: id, position: "a\(id)")
        }

        let vm = makeVM(playlist: playlist, playlistRepo: plRepo, trackRepo: trRepo, sourceRepo: srRepo)
        await vm.loadTracks()

        // Move track 5 to index 1.
        await vm.placeTracks([5], at: 1)

        let positions = try await fetchPositions(playlistId: pid, from: db)
        let posStrings = positions.map(\.position)

        // The SQL ORDER BY order matches the array order.
        #expect(positions.map(\.trackId) == vm.tracks.map(\.id))

        // Positions are strictly ascending.
        for i in 1..<posStrings.count {
            #expect(posStrings[i - 1] < posStrings[i])
        }
    }
}
