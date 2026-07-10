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
        genre: String? = nil,
        format: String = "mp3",
        organizedPath: String?,
        dateAdded: String? = nil,
        bitrate: Int? = nil
    ) async throws {
        try await db.write { db in
            var t = Track(artist: artist, album: album, title: title, format: format,
                          originalPath: "/\(title).\(format)")
            t.genre = genre
            t.organizedPath = organizedPath
            t.dateAdded = dateAdded ?? "2024-01-01T00:00:00Z"
            t.bitrate = bitrate
            t.searchText = DatabaseManager.foldedSearchText(t.rawSearchText)
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

    // MARK: - fetchForLibrary: diacritic-insensitive search

    @Test func searchIsDiacriticInsensitive() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "Yeat", album: "Up 2 Më", title: "Ön Thë Linë",
                              organizedPath: "Yeat/Up 2 Me/On The Line.mp3")
        try await insertTrack(db, artist: "Olivés", album: "Normal Album", title: "Regular Track",
                              organizedPath: "Olives/Normal/Track.mp3")
        try await insertTrack(db, artist: "Other", album: "Other", title: "Nothing",
                              organizedPath: "Other/Other/Nothing.mp3")

        // ASCII query finds diacritic-heavy title
        let byTitle = try await repo.fetchForLibrary(tab: .local, search: "on the line", sortBy: .title, ascending: true)
        #expect(byTitle.count == 1)
        #expect(byTitle[0].title == "Ön Thë Linë")

        // ASCII query finds diacritic album name
        let byAlbum = try await repo.fetchForLibrary(tab: .local, search: "up 2 me", sortBy: .title, ascending: true)
        #expect(byAlbum.count == 1)
        #expect(byAlbum[0].artist == "Yeat")

        // All-uppercase ASCII query (case + diacritic insensitive)
        let byUpper = try await repo.fetchForLibrary(tab: .local, search: "ON THE LINE", sortBy: .title, ascending: true)
        #expect(byUpper.count == 1)
        #expect(byUpper[0].title == "Ön Thë Linë")

        // Diacritic in artist name found by ASCII
        let byDiacriticArtist = try await repo.fetchForLibrary(tab: .local, search: "olives", sortBy: .title, ascending: true)
        #expect(byDiacriticArtist.count == 1)
        #expect(byDiacriticArtist[0].artist == "Olivés")
    }

    // MARK: - fetchForLibrary: multi-term and cross-field search
    
    @Test func fetchForLibraryMultiTermCrossFieldSearch() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "DJ Hazel", album: "Classic", title: "Sunrise", genre: "Vixa", format: "flac", organizedPath: "DJ Hazel/Sunrise.flac")
        try await insertTrack(db, artist: "DJ Hazel", album: "Classic", title: "Sunset", genre: "House", format: "mp3", organizedPath: "DJ Hazel/Sunset.mp3")
        try await insertTrack(db, artist: "Armin van Buuren", album: "State of Trance", title: "Shivers", genre: "Trance", format: "flac", organizedPath: "Armin/Shivers.flac")
        
        // 1. Matches artist + genre + format
        let results1 = try await repo.fetchForLibrary(tab: .local, search: "hazel vixa flac", sortBy: .title, ascending: true)
        #expect(results1.count == 1)
        #expect(results1.first?.title == "Sunrise")
        
        // 2. Term order does not matter
        let results2 = try await repo.fetchForLibrary(tab: .local, search: "flac vixa hazel", sortBy: .title, ascending: true)
        #expect(results2.count == 1)
        #expect(results2.first?.title == "Sunrise")
        
        // 3. Multi-word search matching single tracks
        let results3 = try await repo.fetchForLibrary(tab: .local, search: "armin shivers", sortBy: .title, ascending: true)
        #expect(results3.count == 1)
        #expect(results3.first?.title == "Shivers")
        
        // 4. All terms must match (AND condition)
        let results4 = try await repo.fetchForLibrary(tab: .local, search: "hazel vixa mp3", sortBy: .title, ascending: true)
        #expect(results4.isEmpty)
    }

    @Test func trackInMemoryMatchesMultiTermQuery() {
        let track = Track(
            artist: "DJ Hazel",
            albumArtist: "DJ Hazel",
            album: "Classic",
            title: "Sunrise",
            format: "flac",
            originalPath: "/Sunrise.flac"
        )
        var mutTrack = track
        mutTrack.genre = "Vixa"
        
        // Exact case match
        #expect(mutTrack.matches(searchQuery: "hazel vixa flac"))
        // Multi-term random order
        #expect(mutTrack.matches(searchQuery: "flac vixa hazel"))
        // Case / diacritic insensitivity
        #expect(mutTrack.matches(searchQuery: "HAZEL Vîxâ FLAC"))
        // Partial matches on terms
        #expect(mutTrack.matches(searchQuery: "haz vix fla"))
        // Non-matching term fails
        #expect(!mutTrack.matches(searchQuery: "hazel vixa mp3"))
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

    // MARK: - fetchTracksByOriginalPaths

    @Test func fetchTracksByOriginalPathsMatchesOnlyRequestedPaths() async throws {
        let (db, repo) = try makeRepo()
        try await db.write { db in
            var t1 = Track(artist: "A", album: "X", title: "Song A", format: "mp3",
                           originalPath: "/music/artist/song_a.mp3")
            t1.organizedPath = "A/X/song_a.mp3"
            t1.dateAdded = "2024-01-01T00:00:00Z"
            try t1.insert(db)

            var t2 = Track(artist: "B", album: "Y", title: "Song B", format: "flac",
                           originalPath: "/music/other/song_b.flac")
            t2.organizedPath = "B/Y/song_b.flac"
            t2.dateAdded = "2024-01-01T00:00:00Z"
            try t2.insert(db)
        }

        let result = try await repo.fetchTracksByOriginalPaths(["/music/artist/song_a.mp3"])
        #expect(result.count == 1)
        #expect(result[0].title == "Song A")
    }

    @Test func fetchTracksByOriginalPathsReturnsEmptyForEmptyInput() async throws {
        let (_, repo) = try makeRepo()
        let result = try await repo.fetchTracksByOriginalPaths([])
        #expect(result.isEmpty)
    }

    @Test func fetchTracksByOriginalPathsMatchesMultiplePaths() async throws {
        let (db, repo) = try makeRepo()
        try await db.write { db in
            for i in 1...4 {
                var t = Track(artist: "A", album: "X", title: "T\(i)", format: "mp3",
                              originalPath: "/music/t\(i).mp3")
                t.dateAdded = "2024-01-01T00:00:00Z"
                try t.insert(db)
            }
        }

        let result = try await repo.fetchTracksByOriginalPaths(["/music/t1.mp3", "/music/t3.mp3"])
        #expect(result.count == 2)
        let titles = result.map(\.title).sorted()
        #expect(titles == ["T1", "T3"])
    }
}

