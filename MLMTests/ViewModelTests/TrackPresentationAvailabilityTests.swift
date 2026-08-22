import Foundation
import Testing
@testable import MLM

@Suite("TrackPresentationAvailabilityTests")
struct TrackPresentationAvailabilityTests {
    @Test func mapsVerifiedAvailabilityUsingOneLibraryRootSnapshot() throws {
        let libraryRoot = URL(fileURLWithPath: "/library")
        let failure = TrackDownloadFailure(
            reason: "Provider unavailable",
            date: Date(timeIntervalSince1970: 1_720_000_000),
            attempts: 2
        )

        var localTrack = makeTrack(id: 1)
        localTrack.organizedPath = "Artist/Album/Local.m4a"

        var missingTrack = makeTrack(id: 2)
        missingTrack.organizedPath = "Artist/Album/Missing.m4a"

        var downloadingTrack = makeTrack(id: 3)
        downloadingTrack.downloadStatus = "downloading"

        var failedTrack = makeTrack(id: 4)
        try failedTrack.setDownloadFailureRecord(failure)

        let remoteTrack = makeTrack(id: 5)
        let availability = TrackPresentationAvailability.map(
            tracks: [localTrack, missingTrack, downloadingTrack, failedTrack, remoteTrack],
            libraryRoot: libraryRoot,
            fileExists: { $0.path == "/library/Artist/Album/Local.m4a" }
        )

        #expect(availability[1] == .local)
        #expect(availability[2] == .fileMissing)
        #expect(availability[3] == .downloading)
        #expect(availability[4] == .failed(
            reason: "Provider unavailable",
            date: Date(timeIntervalSince1970: 1_720_000_000),
            attempts: 2
        ))
        #expect(availability[5] == .notDownloaded)
    }

    @Test func identifiesOnlyKnownImportPlaceholderMetadata() {
        #expect(TrackMetadataPresentation.isPlaceholder("YouTube"))
        #expect(TrackMetadataPresentation.isPlaceholder("SoundCloud Likes"))
        #expect(TrackMetadataPresentation.isPlaceholder("Discovered Neighbors"))
        #expect(TrackMetadataPresentation.isPlaceholder("Reels Inbox Imports"))
        #expect(TrackMetadataPresentation.isPlaceholder("Downloads"))
        #expect(TrackMetadataPresentation.isPlaceholder(" Unknown "))
        #expect(!TrackMetadataPresentation.isPlaceholder("Unknown Artist"))
        #expect(!TrackMetadataPresentation.isPlaceholder("The Downloads"))
    }

    @Test func leavesRelativeLocalPathsLocalUntilTheRootSnapshotLoads() {
        var track = makeTrack(id: 1)
        track.organizedPath = "Artist/Album/Track.m4a"

        let availability = TrackPresentationAvailability.map(
            tracks: [track],
            libraryRoot: nil,
            fileExists: { _ in false }
        )

        #expect(availability[1] == .local)
    }

    private func makeTrack(id: Int64) -> Track {
        var track = Track(
            artist: "Artist",
            album: "Album",
            title: "Track",
            format: "m4a",
            originalPath: "source://track"
        )
        track.id = id
        return track
    }
}
