import Testing
import GRDB
@testable import MLM

struct TrackRepositoryTests {

    // MARK: - Helpers

    private func makeRepo() throws -> (DatabaseQueue, TrackRepository) {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        return (db, repo)
    }

    private func insertTrack(
        _ db: DatabaseQueue,
        artist: String,
        album: String,
        title: String,
        organizedPath: String?,
        dateAdded: String? = nil,
        bitrate: Int? = nil
    ) async throws {
        try await db.write { db in
            var t = Track(artist: artist, album: album, title: title, format: "mp3",
                          originalPath: "/\(title).mp3")
            t.organizedPath = organizedPath
            t.dateAdded = dateAdded ?? "2024-01-01T00:00:00Z"
            t.bitrate = bitrate
            try t.insert(db)
        }
    }

    // MARK: - fetchForLibrary: tab filter

    @Test func fetchForLibraryLocalTabReturnsOnlyLocalTracks() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "A", album: "X", title: "Local1", organizedPath: "A/X/Local1.mp3")
        try await insertTrack(db, artist: "B", album: "Y", title: "Remote1", organizedPath: nil)

        let results = try await repo.fetchForLibrary(tab: .local, search: nil, sortBy: .title, ascending: true)
        #expect(results.count == 1)
        #expect(results[0].title == "Local1")
    }

    @Test func fetchForLibraryRemoteTabReturnsOnlyRemoteTracks() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "A", album: "X", title: "Local1", organizedPath: "A/X/Local1.mp3")
        try await insertTrack(db, artist: "B", album: "Y", title: "Remote1", organizedPath: nil)

        let results = try await repo.fetchForLibrary(tab: .remote, search: nil, sortBy: .title, ascending: true)
        #expect(results.count == 1)
        #expect(results[0].title == "Remote1")
    }

    // MARK: - fetchForLibrary: search

    @Test func fetchForLibrarySearchFiltersByTitleArtistAlbum() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "Aphex Twin", album: "Selected", title: "Windowlicker", organizedPath: "Aphex Twin/Selected/W.mp3")
        try await insertTrack(db, artist: "Burial", album: "Untrue", title: "Archangel", organizedPath: "Burial/Untrue/A.mp3")
        try await insertTrack(db, artist: "Boards of Canada", album: "Music Has", title: "Wildlife Analysis", organizedPath: "BoC/MH/WA.mp3")

        // Search by artist fragment
        let byArtist = try await repo.fetchForLibrary(tab: .local, search: "burial", sortBy: .title, ascending: true)
        #expect(byArtist.count == 1)
        #expect(byArtist[0].artist == "Burial")

        // Search by title fragment
        let byTitle = try await repo.fetchForLibrary(tab: .local, search: "wildlife", sortBy: .title, ascending: true)
        #expect(byTitle.count == 1)
        #expect(byTitle[0].title == "Wildlife Analysis")

        // Non-matching search returns empty
        let noMatch = try await repo.fetchForLibrary(tab: .local, search: "zzznomatch", sortBy: .title, ascending: true)
        #expect(noMatch.isEmpty)
    }

    // MARK: - fetchForLibrary: sort order

    @Test func fetchForLibrarySortsByTitleAscending() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "A", album: "X", title: "Zebra",    organizedPath: "A/X/Z.mp3")
        try await insertTrack(db, artist: "A", album: "X", title: "Apple",    organizedPath: "A/X/A.mp3")
        try await insertTrack(db, artist: "A", album: "X", title: "Midnight", organizedPath: "A/X/M.mp3")

        let asc = try await repo.fetchForLibrary(tab: .local, search: nil, sortBy: .title, ascending: true)
        #expect(asc.map(\.title) == ["Apple", "Midnight", "Zebra"])

        let desc = try await repo.fetchForLibrary(tab: .local, search: nil, sortBy: .title, ascending: false)
        #expect(desc.map(\.title) == ["Zebra", "Midnight", "Apple"])
    }

    @Test func fetchForLibrarySortsByBitrateDescending() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "A", album: "X", title: "T1", organizedPath: "A/X/T1.mp3", bitrate: 128)
        try await insertTrack(db, artist: "A", album: "X", title: "T2", organizedPath: "A/X/T2.mp3", bitrate: 320)
        try await insertTrack(db, artist: "A", album: "X", title: "T3", organizedPath: "A/X/T3.mp3", bitrate: 248)

        let desc = try await repo.fetchForLibrary(tab: .local, search: nil, sortBy: .bitrate, ascending: false)
        #expect(desc[0].bitrate == 320)
        #expect(desc[1].bitrate == 248)
        #expect(desc[2].bitrate == 128)
    }

    // MARK: - fetchAllOrganizedPaths

    @Test func fetchAllOrganizedPathsReturnsAllNonNullPaths() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "A", album: "X", title: "T1", organizedPath: "A/X/T1.mp3")
        try await insertTrack(db, artist: "A", album: "X", title: "T2", organizedPath: "A/X/T2.mp3")
        try await insertTrack(db, artist: "B", album: "Y", title: "T3", organizedPath: nil)

        let paths = try await repo.fetchAllOrganizedPaths()
        #expect(paths.count == 2)
        #expect(paths.contains("A/X/T1.mp3"))
        #expect(paths.contains("A/X/T2.mp3"))
    }

    // MARK: - fetchTracksInFolder

    @Test func fetchTracksInFolderReturnsOnlyDirectChildren() async throws {
        let (db, repo) = try makeRepo()
        // Direct children of "Artist/Album"
        try await insertTrack(db, artist: "A", album: "X", title: "T1", organizedPath: "Artist/Album/T1.mp3")
        try await insertTrack(db, artist: "A", album: "X", title: "T2", organizedPath: "Artist/Album/T2.mp3")
        // Deeper (should be excluded)
        try await insertTrack(db, artist: "A", album: "X", title: "T3", organizedPath: "Artist/Album/CD1/T3.mp3")
        // Different folder (should be excluded)
        try await insertTrack(db, artist: "B", album: "Y", title: "T4", organizedPath: "Other/Album/T4.mp3")

        let tracks = try await repo.fetchTracksInFolder(path: "Artist/Album")
        #expect(tracks.count == 2)
        #expect(tracks.allSatisfy { $0.organizedPath?.hasPrefix("Artist/Album/") == true })
        #expect(!tracks.contains(where: { $0.title == "T3" }))
        #expect(!tracks.contains(where: { $0.title == "T4" }))
    }
}

// MARK: - FolderViewModel tree build tests

struct FolderTreeBuildTests {

    /// Create a minimal in-memory repo with the given organized_path values.
    private func makeViewModel(paths: [String]) async throws -> FolderViewModel {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)

        try await db.write { (dbConn: Database) in
            for (i, path) in paths.enumerated() {
                var t = Track(artist: "A\(i)", album: "B\(i)", title: "T\(i)",
                              format: "mp3", originalPath: "/t\(i).mp3")
                t.organizedPath = path
                t.dateAdded = "2024-01-01T00:00:00Z"
                try t.insert(dbConn)
            }
        }

        let vm = FolderViewModel(trackRepository: repo)
        await vm.loadRootFolders()
        return vm
    }

    @Test func treeBuildsCorrectArtistCount() async throws {
        let vm = try await makeViewModel(paths: [
            "Artist A/Album 1/Track 1.mp3",
            "Artist A/Album 1/Track 2.mp3",
            "Artist A/Album 2/Track 3.mp3",
            "Artist B/Album 1/Track 4.mp3",
        ])

        #expect(vm.allRootNodes.count == 2)
        let artists = vm.allRootNodes.map(\.name).sorted()
        #expect(artists == ["Artist A", "Artist B"])
    }

    @Test func treeBuildsCorrectAlbumChildrenForArtist() async throws {
        let vm = try await makeViewModel(paths: [
            "Yeat/Up 2 Më/T1.mp3",
            "Yeat/Up 2 Më/T2.mp3",
            "Yeat/AftërLyfe/T3.mp3",
            "Yeat/AftërLyfe/T4.mp3",
            "Yeat/AftërLyfe/T5.mp3",
        ])

        #expect(vm.allRootNodes.count == 1)
        let artist = try #require(vm.allRootNodes.first)
        #expect(artist.name == "Yeat")
        let albums = try #require(artist.children)
        #expect(albums.count == 2)

        let albumNames = albums.map(\.name).sorted()
        #expect(albumNames.contains("Up 2 Më"))
        #expect(albumNames.contains("AftërLyfe"))
    }

    @Test func albumTrackCountsAreCorrect() async throws {
        let vm = try await makeViewModel(paths: [
            "Drake/Views/T1.mp3",
            "Drake/Views/T2.mp3",
            "Drake/Views/T3.mp3",
            "Drake/Certified/T4.mp3",
        ])

        let artist = try #require(vm.allRootNodes.first)
        let albums = try #require(artist.children)
        let views = try #require(albums.first(where: { $0.name == "Views" }))
        let certified = try #require(albums.first(where: { $0.name == "Certified" }))

        #expect(views.trackCount == 3)
        #expect(certified.trackCount == 1)
    }

    @Test func treeChildrenArePreloaded() async throws {
        let vm = try await makeViewModel(paths: [
            "Artist/Album/Track.mp3",
        ])

        let artist = try #require(vm.allRootNodes.first)
        // All nodes should be pre-loaded (children != nil)
        #expect(artist.isLoaded)
        let album = try #require(artist.children?.first)
        #expect(album.isLoaded)
        // Album is a leaf: empty children array
        #expect(album.children?.isEmpty == true)
    }

    @Test func searchFilterReducesRootNodes() async throws {
        let vm = try await makeViewModel(paths: [
            "Aphex Twin/Selected/T1.mp3",
            "Burial/Untrue/T2.mp3",
            "Boards of Canada/Music Has/T3.mp3",
        ])

        vm.searchQuery = "burial"
        #expect(vm.rootNodes.count == 1)
        #expect(vm.rootNodes[0].name == "Burial")

        vm.searchQuery = ""
        #expect(vm.rootNodes.count == 3)
    }

    @Test func totalTrackCountMatchesInsertedPaths() async throws {
        let vm = try await makeViewModel(paths: [
            "A/B/T1.mp3", "A/B/T2.mp3", "C/D/T3.mp3",
        ])
        #expect(vm.totalTrackCount == 3)
    }
}
