import Foundation
import GRDB
import Testing
@testable import MLM

/// Availability is derived from persisted fields only (W2-A, UC-TABLE-20). The disk-probing
/// cases of the old suite (present / absent organized file, stale organized path with an
/// existing original file) moved to `TrackAvailabilityReconcilerTests`, where the disk is
/// compared now.
@Suite("TrackAvailabilityTests")
struct TrackAvailabilityTests {
    private static let failureJSON = try! TrackDownloadFailure(
        reason: "Source timed out", date: Date(timeIntervalSince1970: 1_720_000_000), attempts: 2
    ).encodedJSON()

    /// Every combination of the four persisted inputs maps to exactly one state.
    @Test(arguments: [
        // organized, missingSince, status, failure → expected
        (String?.none, String?.none, String?.none, String?.none, "notDownloaded"),
        (nil, nil, "remote", nil, "notDownloaded"),
        (nil, nil, "completed", nil, "notDownloaded"),
        ("", nil, nil, nil, "notDownloaded"),
        (nil, nil, "downloading", nil, "downloading"),
        (nil, nil, " Queued ", nil, "downloading"),
        (nil, nil, "in_progress", nil, "downloading"),
        (nil, nil, "downloading", failureJSON, "downloading"),
        (nil, nil, "failed", nil, "failed"),
        (nil, nil, "error", nil, "failed"),
        (nil, nil, nil, failureJSON, "failed"),
        (nil, nil, "failed", "{not json", "failed"),
        (nil, "2026-10-05T10:00:00Z", nil, nil, "notDownloaded"),
        ("A/B.m4a", nil, nil, nil, "local"),
        ("A/B.m4a", nil, "2026-01-01T00:00:00Z", nil, "local"),
        ("A/B.m4a", "", nil, nil, "local"),
        ("A/B.m4a", "2026-10-05T10:00:00Z", nil, nil, "fileMissing"),
        ("/Volumes/X/B.m4a", "2026-10-05T10:00:00Z", "failed", failureJSON, "fileMissing"),
        ("A/B.m4a", nil, "downloading", failureJSON, "local"),
    ])
    func derivation(organized: String?, missingSince: String?, status: String?, failure: String?, expected: String) {
        let availability = TrackAvailability.derive(
            organizedPath: organized, fileMissingSince: missingSince, downloadStatus: status, downloadFailure: failure
        )
        #expect(Self.name(availability) == expected)
    }

    @Test func failureRecordCarriesReasonDateAndAttempts() throws {
        var failed = makeTrack()
        try failed.setDownloadFailureRecord(TrackDownloadFailure(
            reason: "Source timed out", date: Date(timeIntervalSince1970: 1_720_000_000), attempts: 2))
        #expect(failed.availability() == .failed(
            reason: "Source timed out", date: Date(timeIntervalSince1970: 1_720_000_000), attempts: 2))
        #expect(makeTrack().availability() == .notDownloaded)
    }

    @Test func availabilityNeverTouchesTheDisk() {
        // A relative path with no root and a path that surely doesn't exist are both Local:
        // only the persisted fact says File missing.
        var track = makeTrack()
        track.organizedPath = "Nowhere/\(UUID().uuidString).m4a"
        #expect(track.availability() == .local)
        #expect(track.availability(libraryRoot: URL(fileURLWithPath: "/nonexistent")) == .local)
        track.fileMissingSince = "2026-10-05T10:00:00Z"
        #expect(track.availability() == .fileMissing)
    }

    @Test func statusSortRankFollowsTheScopeOrder() {
        let ordered: [TrackAvailability] = [
            .local, .downloading, .notDownloaded, .failed(reason: "", date: .distantPast, attempts: 1), .fileMissing,
        ]
        #expect(ordered.map(\.statusSortRank) == [0, 1, 2, 3, 4])
    }

    @Test func failureRecordAndTrackPersistThroughDatabase() async throws {
        let database = try DatabaseManager.inMemory()
        let failure = TrackDownloadFailure(reason: "Provider unavailable", date: Date(timeIntervalSince1970: 1_720_000_123), attempts: 3)
        var trackWithFailure = makeTrack()
        try trackWithFailure.setDownloadFailureRecord(failure)
        let track = trackWithFailure
        let insertedTrack = try await database.write { db -> Track in
            var record = track
            try record.insert(db)
            return record
        }
        let trackID = try #require(insertedTrack.id)
        let fetched = try await database.read { db in try Track.fetchOne(db, id: trackID) }
        #expect(fetched?.downloadFailureRecord == failure)
        #expect(fetched?.availability() == .failed(reason: failure.reason, date: failure.date, attempts: failure.attempts))
    }

    @Test func migrationAddsDownloadFailureColumnExactlyOnce() async throws {
        let database = try DatabaseManager.inMemory()
        let columns = try await database.read { db in try db.columns(in: "tracks").map(\.name) }
        #expect(columns.filter { $0 == "download_failure" }.count == 1)
    }

    // MARK: - SQL aggregates mirror the derivation

    @Test func aggregateCountsMatchTheDerivationForEveryState() async throws {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        let rows: [(String?, String?, String?, String?)] = [
            ("A/1.m4a", nil, nil, nil),                       // local
            ("A/2.m4a", nil, "2026-01-01", nil),              // local
            ("A/3.m4a", "2026-10-05T10:00:00Z", nil, nil),    // file missing
            (nil, nil, nil, nil),                             // not downloaded
            (nil, nil, "remote", nil),                        // not downloaded
            (nil, nil, "downloading", Self.failureJSON),      // downloading
            (nil, nil, "failed", nil),                        // failed (legacy)
            (nil, nil, nil, Self.failureJSON),                // failed
            ("", nil, nil, nil),                              // not downloaded (empty path)
        ]
        var tracks: [Track] = []
        for (index, row) in rows.enumerated() {
            var track = Track(artist: "Artist \(index)", album: "Album", title: "Song \(index)", format: "m4a",
                              originalPath: "/orig/\(index).m4a")
            track.organizedPath = row.0
            track.downloadStatus = row.2
            track.downloadFailure = row.3
            track.duration = 100
            let inserted = try await repo.insert(track)
            if let missing = row.1, let id = inserted.id {
                try await db.write { db in
                    try db.execute(sql: "UPDATE tracks SET file_missing_since = ? WHERE id = ?", arguments: [missing, id])
                }
            }
            tracks.append(inserted)
        }
        let fetched = try await repo.fetchAllTracks()
        let derived = fetched.map { $0.availability() }
        let counts = try await repo.availabilityCounts()
        #expect(counts.all == 9)
        #expect(counts.local == derived.filter { $0 == .local }.count)
        #expect(counts.local == 2)
        #expect(counts.fileMissing == 1)
        #expect(counts.downloading == 1)
        #expect(counts.failed == 2)
        #expect(counts.notDownloaded == 4)  // 3 not downloaded + 1 downloading
        #expect(counts.totalDuration == 900)
        for scope in TrackAvailabilityScope.allCases {
            let scoped = try await repo.fetchTracks(scope: scope)
            #expect(scoped.count == counts.count(for: scope), "\(scope)")
            #expect(scoped.allSatisfy { scope.contains($0.availability()) }, "\(scope)")
            #expect(derived.filter { scope.contains($0) }.count == counts.count(for: scope), "\(scope)")
        }
        // Counts follow the search.
        let searched = try await repo.availabilityCounts(search: "song 2")
        #expect(searched.all == 1 && searched.fileMissing == 1)
    }

    @Test func changingThePathClearsTheMissingFact() async throws {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        var track = makeTrack()
        track.organizedPath = "A/old.m4a"
        let id = try #require(try await repo.insert(track).id)
        #expect(try await repo.recordFileMissing(trackId: id))
        #expect(try await repo.recordFileMissing(trackId: id) == false)  // already flagged
        try await repo.setOrganizedPathOnly(trackId: id, organizedPath: "A/new.m4a")
        #expect(try await repo.fetchTrack(id: id)?.availability() == .local)
        #expect(try await repo.recordFileMissing(trackId: id))
        try await repo.markAsDownloaded(trackId: id, organizedPath: "A/dl.m4a", format: "m4a", bitrate: 248)
        #expect(try await repo.fetchTrack(id: id)?.fileMissingSince == nil)
        #expect(try await repo.recordFileMissing(trackId: id))
        try await repo.demoteToRemote(trackId: id)
        let demoted = try await repo.fetchTrack(id: id)
        #expect(demoted?.fileMissingSince == nil)
        #expect(demoted?.availability() == .notDownloaded)
        // A track without a file can't be flagged missing.
        #expect(try await repo.recordFileMissing(trackId: id) == false)
    }

    @Test func playlistAddedDatesComeFromTheMembership() async throws {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        let id = try #require(try await repo.insert(makeTrack()).id)
        try await db.write { db in
            try db.execute(sql: "INSERT INTO playlists (name, category) VALUES ('Warm-up', 'regular')")
            let playlistID = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, added_at) VALUES (?, ?, 'a', '2026-09-01T08:00:00Z')",
                           arguments: [playlistID, id])
        }
        let playlistID = try await db.read { try Int64.fetchOne($0, sql: "SELECT id FROM playlists") }
        let dates = try await repo.fetchPlaylistAddedDates(playlistId: try #require(playlistID))
        #expect(dates[id] == "2026-09-01T08:00:00Z")
    }

    private func makeTrack() -> Track {
        Track(artist: "Artist", album: "Album", title: "Track", format: "m4a", originalPath: "soundcloud://track")
    }

    private static func name(_ availability: TrackAvailability) -> String {
        switch availability {
        case .local: "local"
        case .downloading: "downloading"
        case .notDownloaded: "notDownloaded"
        case .failed: "failed"
        case .fileMissing: "fileMissing"
        }
    }
}
