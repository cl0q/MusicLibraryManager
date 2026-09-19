import Foundation
import GRDB
import Testing
@testable import MLM

@Suite("TrackAvailabilityTests")
struct TrackAvailabilityTests {
    @Test func availabilityUsesVerifiedOrganizedPath() {
        var track = makeTrack()
        track.organizedPath = "Artist/Album/Track.m4a"

        let libraryRoot = URL(fileURLWithPath: "/library")
        let present = track.availability(libraryRoot: libraryRoot) { url in
            url.path == "/library/Artist/Album/Track.m4a"
        }
        let absent = track.availability(libraryRoot: libraryRoot) { _ in false }

        #expect(present == .local)
        #expect(absent == .fileMissing)
        #expect(track.isLocal)
        #expect(!track.isRemote)
    }

    @Test func staleOrganizedPathButExistingOriginalPathReturnsLocal() {
        // Regression: old Tauri app rows may have a stale organized_path that no
        // longer exists, while the original import path is still valid.
        // availability() must mirror the PlaybackViewModel.loadAndPlay fallback.
        var track = Track(
            artist: "Artist",
            album: "Album",
            title: "Track",
            format: "m4a",
            originalPath: "/Users/music/real-track.m4a"
        )
        track.organizedPath = "Artist/Album/stale-path.m4a"

        let libraryRoot = URL(fileURLWithPath: "/library")
        let result = track.availability(libraryRoot: libraryRoot) { url in
            // organized path does NOT exist
            if url.path == "/library/Artist/Album/stale-path.m4a" { return false }
            // original path DOES exist
            if url.path == "/Users/music/real-track.m4a" { return true }
            return false
        }
        #expect(result == .local)
    }

    @Test func staleOrganizedPathAndMissingOriginalPathReturnsFileMissing() {
        // When both organized and original paths are absent, .fileMissing is correct.
        var track = Track(
            artist: "Artist",
            album: "Album",
            title: "Track",
            format: "m4a",
            originalPath: "/Users/music/gone.m4a"
        )
        track.organizedPath = "Artist/Album/stale-path.m4a"

        let libraryRoot = URL(fileURLWithPath: "/library")
        let result = track.availability(libraryRoot: libraryRoot) { _ in false }
        #expect(result == .fileMissing)
    }

    @Test func availabilityMapsDownloadStateAndFailureRecord() throws {
        var downloading = makeTrack()
        downloading.downloadStatus = "downloading"
        #expect(downloading.availability() == .downloading)

        var failed = makeTrack()
        let failure = TrackDownloadFailure(
            reason: "Source timed out",
            date: Date(timeIntervalSince1970: 1_720_000_000),
            attempts: 2
        )
        try failed.setDownloadFailureRecord(failure)

        #expect(
            failed.availability() == .failed(
                reason: "Source timed out",
                date: Date(timeIntervalSince1970: 1_720_000_000),
                attempts: 2
            )
        )
        #expect(makeTrack().availability() == .notDownloaded)
    }

    @Test func failureRecordAndTrackPersistThroughDatabase() async throws {
        let database = try DatabaseManager.inMemory()
        let failure = TrackDownloadFailure(
            reason: "Provider unavailable",
            date: Date(timeIntervalSince1970: 1_720_000_123),
            attempts: 3
        )
        var trackWithFailure = makeTrack()
        try trackWithFailure.setDownloadFailureRecord(failure)
        let track = trackWithFailure

        let insertedTrack = try await database.write { db -> Track in
            var record = track
            try record.insert(db)
            return record
        }
        let trackID = try #require(insertedTrack.id)

        let fetched = try await database.read { db in
            try Track.fetchOne(db, id: trackID)
        }
        #expect(fetched?.downloadFailureRecord == failure)
        #expect(
            fetched?.availability() == .failed(
                reason: failure.reason,
                date: failure.date,
                attempts: failure.attempts
            )
        )
    }

    @Test func migrationAddsDownloadFailureColumnExactlyOnce() async throws {
        let database = try DatabaseManager.inMemory()
        let columns = try await database.read { db in
            try db.columns(in: "tracks").map(\.name)
        }

        #expect(columns.filter { $0 == "download_failure" }.count == 1)
    }

    private func makeTrack() -> Track {
        Track(
            artist: "Artist",
            album: "Album",
            title: "Track",
            format: "m4a",
            originalPath: "soundcloud://track"
        )
    }
}
