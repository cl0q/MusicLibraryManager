import Foundation
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

    private func trackID(_ db: DatabaseQueue, title: String) async throws -> Int64 {
        try await db.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT id FROM tracks WHERE title = ?",
                arguments: [title]
            )!
        }
    }

    // MARK: - Download failure persistence

    @Test func downloadFailureJSONRoundTripsAndReconcilesLegacyRetryAttempts() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(
            db,
            artist: "Artist",
            album: "Remote",
            title: "Failed Download",
            format: "youtube",
            organizedPath: nil
        )
        let id = try await trackID(db, title: "Failed Download")
        let firstDate = Date(timeIntervalSince1970: 1_720_000_000)
        let secondDate = Date(timeIntervalSince1970: 1_720_000_001)

        let first = try await repo.persistDownloadFailure(
            trackId: id,
            reason: "Video unavailable",
            date: firstDate
        )
        let reconciled = try await repo.persistDownloadFailure(
            trackId: id,
            reason: "Network error",
            date: secondDate,
            minimumAttempts: 4
        )
        let fetched = try await repo.fetchTrack(id: id)

        #expect(first == TrackDownloadFailure(
            reason: "Video unavailable",
            date: firstDate,
            attempts: 1
        ))
        #expect(reconciled == TrackDownloadFailure(
            reason: "Network error",
            date: secondDate,
            attempts: 4
        ))
        #expect(fetched?.downloadFailureRecord == reconciled)
        #expect(fetched?.downloadStatus == "failed")
    }

    @Test func downloadingStateTransitionsThroughCancelFailureAndSuccess() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(
            db,
            artist: "Artist",
            album: "Remote",
            title: "Lifecycle",
            format: "youtube",
            organizedPath: nil
        )
        let id = try await trackID(db, title: "Lifecycle")

        try await repo.markDownloadsInProgress(trackIds: [id])
        var fetched = try await repo.fetchTrack(id: id)
        #expect(fetched?.downloadStatus == "downloading")
        #expect(fetched?.availability() == .downloading)

        try await repo.clearDownloadsInProgress(trackIds: [id])
        fetched = try await repo.fetchTrack(id: id)
        #expect(fetched?.downloadStatus == nil)
        #expect(fetched?.availability() == .notDownloaded)

        try await repo.markDownloadsInProgress(trackIds: [id])
        _ = try await repo.persistDownloadFailure(
            trackId: id,
            reason: "Video unavailable"
        )
        fetched = try await repo.fetchTrack(id: id)
        #expect(fetched?.downloadStatus == "failed")
        #expect(fetched?.availability() != .downloading)

        // A retry keeps the durable history but exposes its truthful active
        // state until it terminates.
        try await repo.markDownloadsInProgress(trackIds: [id])
        fetched = try await repo.fetchTrack(id: id)
        #expect(fetched?.availability() == .downloading)
        try await repo.clearDownloadsInProgress(trackIds: [id])
        fetched = try await repo.fetchTrack(id: id)
        #expect(fetched?.downloadStatus == "failed")

        try await repo.markDownloadsInProgress(trackIds: [id])
        try await repo.markAsDownloaded(
            trackId: id,
            organizedPath: "00_Artists/Lifecycle.m4a",
            format: "m4a",
            bitrate: 248,
            downloadStatus: "2026-08-06T12:00:00Z"
        )
        fetched = try await repo.fetchTrack(id: id)
        #expect(fetched?.downloadStatus == "2026-08-06T12:00:00Z")
        #expect(fetched?.downloadFailure == nil)
        #expect(fetched?.organizedPath == "00_Artists/Lifecycle.m4a")
    }

    @Test func failureQueryIncludesLegacyDownloadStatusRows() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(
            db,
            artist: "Artist",
            album: "Remote",
            title: "Legacy Failure",
            format: "youtube",
            organizedPath: nil
        )
        let id = try await trackID(db, title: "Legacy Failure")
        try await db.write { db in
            try db.execute(
                sql: "UPDATE tracks SET download_status = 'failed' WHERE id = ?",
                arguments: [id]
            )
        }

        let failures = try await repo.fetchTracksWithDownloadFailures()

        #expect(failures.map(\.id) == [id])
        #expect(failures.first?.downloadFailureRecord == nil)
        #expect(failures.first?.availability() == .failed(
            reason: "Download failed",
            date: .distantPast,
            attempts: 1
        ))
    }

    @Test func successfulDownloadAtomicallyClearsPersistedFailure() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(
            db,
            artist: "Artist",
            album: "Remote",
            title: "Recovered Download",
            format: "youtube",
            organizedPath: nil
        )
        let id = try await trackID(db, title: "Recovered Download")
        _ = try await repo.persistDownloadFailure(
            trackId: id,
            reason: "Video unavailable"
        )

        try await repo.markAsDownloaded(
            trackId: id,
            organizedPath: "00_Artists/Recovered Download.m4a",
            format: "m4a",
            bitrate: 248,
            downloadStatus: "2026-08-06T12:00:00Z"
        )
        let fetched = try await repo.fetchTrack(id: id)

        #expect(fetched?.downloadFailure == nil)
        #expect(fetched?.downloadFailureRecord == nil)
        #expect(fetched?.organizedPath == "00_Artists/Recovered Download.m4a")
    }

    // MARK: - fetchTracks(scope:search:): diacritic-insensitive search

    @Test func searchIsDiacriticInsensitive() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "Yeat", album: "Up 2 Më", title: "Ön Thë Linë",
                              organizedPath: "Yeat/Up 2 Me/On The Line.mp3")
        try await insertTrack(db, artist: "Olivés", album: "Normal Album", title: "Regular Track",
                              organizedPath: "Olives/Normal/Track.mp3")
        try await insertTrack(db, artist: "Other", album: "Other", title: "Nothing",
                              organizedPath: "Other/Other/Nothing.mp3")

        // ASCII query finds diacritic-heavy title
        let byTitle = try await repo.fetchTracks(scope: .local, search: "on the line")
        #expect(byTitle.count == 1)
        #expect(byTitle[0].title == "Ön Thë Linë")

        // ASCII query finds diacritic album name
        let byAlbum = try await repo.fetchTracks(scope: .local, search: "up 2 me")
        #expect(byAlbum.count == 1)
        #expect(byAlbum[0].artist == "Yeat")

        // All-uppercase ASCII query (case + diacritic insensitive)
        let byUpper = try await repo.fetchTracks(scope: .local, search: "ON THE LINE")
        #expect(byUpper.count == 1)
        #expect(byUpper[0].title == "Ön Thë Linë")

        // Diacritic in artist name found by ASCII
        let byDiacriticArtist = try await repo.fetchTracks(scope: .local, search: "olives")
        #expect(byDiacriticArtist.count == 1)
        #expect(byDiacriticArtist[0].artist == "Olivés")
    }

    // MARK: - fetchTracks(scope:search:): multi-term and cross-field search
    
    @Test func multiTermCrossFieldSearch() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "DJ Hazel", album: "Classic", title: "Sunrise", genre: "Vixa", format: "flac", organizedPath: "DJ Hazel/Sunrise.flac")
        try await insertTrack(db, artist: "DJ Hazel", album: "Classic", title: "Sunset", genre: "House", format: "mp3", organizedPath: "DJ Hazel/Sunset.mp3")
        try await insertTrack(db, artist: "Armin van Buuren", album: "State of Trance", title: "Shivers", genre: "Trance", format: "flac", organizedPath: "Armin/Shivers.flac")
        
        // 1. Matches artist + genre + format
        let results1 = try await repo.fetchTracks(scope: .local, search: "hazel vixa flac")
        #expect(results1.count == 1)
        #expect(results1.first?.title == "Sunrise")
        
        // 2. Term order does not matter
        let results2 = try await repo.fetchTracks(scope: .local, search: "flac vixa hazel")
        #expect(results2.count == 1)
        #expect(results2.first?.title == "Sunrise")
        
        // 3. Multi-word search matching single tracks
        let results3 = try await repo.fetchTracks(scope: .local, search: "armin shivers")
        #expect(results3.count == 1)
        #expect(results3.first?.title == "Shivers")
        
        // 4. All terms must match (AND condition)
        let results4 = try await repo.fetchTracks(scope: .local, search: "hazel vixa mp3")
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

    // MARK: - fetchTracksWithoutArtwork vs fetchTracksEligibleForProviderArtwork (SCDL-08)

    /// Insert an artwork row directly (bypassing AnalysisRepository — this test
    /// only needs the raw row shape, not save-side business logic).
    private func insertArtwork(_ db: DatabaseQueue, trackId: Int64, artworkPath: String?, source: String?) async throws {
        try await db.write { db in
            let artwork = Artwork(
                trackId: trackId,
                artworkPath: artworkPath,
                source: source,
                musicbrainzReleaseGroupId: nil,
                resolution: nil,
                fetchedAt: "2024-01-01T00:00:00Z"
            )
            try artwork.insert(db)
        }
    }

    @Test func fetchTracksWithoutArtworkExcludesSentinelRows() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "A", album: "X", title: "Sentinel", organizedPath: "A/X/Sentinel.mp3")
        let trackId = try await db.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE title = 'Sentinel'")!
        }
        // Sentinel row: NULL artwork_path, source "none" — written when embedded
        // extraction found no art. Embedded pass must NOT see this track again
        // (otherwise ffmpeg re-runs over it on every import).
        try await insertArtwork(db, trackId: trackId, artworkPath: nil, source: "none")

        let results = try await repo.fetchTracksWithoutArtwork()
        #expect(!results.contains(where: { $0.title == "Sentinel" }), "Embedded pass must stay exclusive of sentinel rows")
    }

    @Test func fetchTracksEligibleForProviderArtworkIncludesSentinelRows() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "A", album: "X", title: "Sentinel", organizedPath: "A/X/Sentinel.mp3")
        let trackId = try await db.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE title = 'Sentinel'")!
        }
        try await insertArtwork(db, trackId: trackId, artworkPath: nil, source: "none")

        let results = try await repo.fetchTracksEligibleForProviderArtwork()
        #expect(results.contains(where: { $0.title == "Sentinel" }), "Provider/MusicBrainz pass must still see sentinel rows")
    }

    @Test func neitherQueryReturnsTrackWithRealArtwork() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "A", album: "X", title: "HasArt", organizedPath: "A/X/HasArt.mp3")
        let trackId = try await db.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE title = 'HasArt'")!
        }
        try await insertArtwork(db, trackId: trackId, artworkPath: "/cache/HasArt_1200.jpg", source: "embedded")

        let withoutArtwork = try await repo.fetchTracksWithoutArtwork()
        let eligibleForProvider = try await repo.fetchTracksEligibleForProviderArtwork()
        #expect(!withoutArtwork.contains(where: { $0.title == "HasArt" }))
        #expect(!eligibleForProvider.contains(where: { $0.title == "HasArt" }))
    }

    @Test func bothQueriesReturnTrackWithNoArtworkRowAtAll() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(db, artist: "A", album: "X", title: "NoRow", organizedPath: "A/X/NoRow.mp3")
        // No artwork row inserted at all.

        let withoutArtwork = try await repo.fetchTracksWithoutArtwork()
        let eligibleForProvider = try await repo.fetchTracksEligibleForProviderArtwork()
        #expect(withoutArtwork.contains(where: { $0.title == "NoRow" }))
        #expect(eligibleForProvider.contains(where: { $0.title == "NoRow" }))
    }

    // MARK: - Retained provider artwork URL (SCDL-08)

    @Test func artworkRemoteURLMigrationAddsNullableColumn() async throws {
        let (db, _) = try makeRepo()
        let columns = try await db.read { db in
            try db.columns(in: "artwork")
        }

        let remoteURLColumn = columns.first { $0.name == "remote_url" }
        #expect(remoteURLColumn != nil)
    }

    @Test func setRemoteArtworkURLInsertsSentinelWhenArtworkIsAbsent() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(
            db,
            artist: "A",
            album: "X",
            title: "RemoteArt",
            organizedPath: "A/X/RemoteArt.m4a"
        )
        let trackId = try await db.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE title = 'RemoteArt'")!
        }

        try await repo.setRemoteArtworkURL(
            trackId: trackId,
            url: "https://i1.sndcdn.com/art.jpg"
        )

        let artwork = try await AnalysisRepository(database: db).fetchArtwork(trackId: trackId)
        #expect(artwork?.source == "soundcloud")
        #expect(artwork?.artworkPath == nil)
        #expect(artwork?.remoteUrl == "https://i1.sndcdn.com/art.jpg")
    }

    @Test func setRemoteArtworkURLNeverClobbersExistingCoverOrSource() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(
            db,
            artist: "A",
            album: "X",
            title: "EmbeddedArt",
            organizedPath: "A/X/EmbeddedArt.m4a"
        )
        let trackId = try await db.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE title = 'EmbeddedArt'")!
        }
        try await insertArtwork(
            db,
            trackId: trackId,
            artworkPath: "/covers/existing.jpg",
            source: "embedded"
        )

        try await repo.setRemoteArtworkURL(
            trackId: trackId,
            url: "https://i1.sndcdn.com/new-art.jpg"
        )

        let artwork = try await AnalysisRepository(database: db).fetchArtwork(trackId: trackId)
        #expect(artwork?.artworkPath == "/covers/existing.jpg")
        #expect(artwork?.source == "embedded")
        #expect(artwork?.remoteUrl == "https://i1.sndcdn.com/new-art.jpg")
    }

    @Test func setRemoteArtworkURLMaintainsOneRowAndUsesLatestURL() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(
            db,
            artist: "A",
            album: "X",
            title: "OneRow",
            organizedPath: "A/X/OneRow.m4a"
        )
        let trackId = try await db.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE title = 'OneRow'")!
        }

        try await repo.setRemoteArtworkURL(trackId: trackId, url: "https://i1.sndcdn.com/old.jpg")
        try await repo.setRemoteArtworkURL(trackId: trackId, url: "https://i1.sndcdn.com/latest.jpg")

        let rowCount = try await db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM artwork WHERE track_id = ?",
                arguments: [trackId]
            )
        }
        let remoteURL = try await AnalysisRepository(database: db).remoteArtworkURL(trackId: trackId)
        #expect(rowCount == 1)
        #expect(remoteURL == "https://i1.sndcdn.com/latest.jpg")
    }

    @Test func savingArtworkWithoutRemoteURLPreservesRetainedProviderURL() async throws {
        let (db, repo) = try makeRepo()
        try await insertTrack(
            db,
            artist: "A",
            album: "X",
            title: "RetainedProviderArt",
            organizedPath: "A/X/RetainedProviderArt.m4a"
        )
        let trackId = try await db.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT id FROM tracks WHERE title = 'RetainedProviderArt'"
            )!
        }
        try await repo.setRemoteArtworkURL(
            trackId: trackId,
            url: "https://i1.sndcdn.com/retained.jpg"
        )

        let analysis = AnalysisRepository(database: db)
        try await analysis.saveArtwork(
            Artwork(
                trackId: trackId,
                artworkPath: "/covers/embedded.jpg",
                source: "embedded",
                musicbrainzReleaseGroupId: nil,
                resolution: "1200",
                fetchedAt: "2026-07-21T00:00:00Z"
            )
        )

        let artwork = try await analysis.fetchArtwork(trackId: trackId)
        #expect(artwork?.artworkPath == "/covers/embedded.jpg")
        #expect(artwork?.source == "embedded")
        #expect(artwork?.remoteUrl == "https://i1.sndcdn.com/retained.jpg")
    }
}
