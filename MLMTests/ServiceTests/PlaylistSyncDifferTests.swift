import Foundation
import Testing
@testable import MLM

/// Tests for `PlaylistSyncDiffer` — incremental playlist diffing.
///
/// Module 2 contract: Given a remote playlist's current entries and the
/// existing local playlist's track data, compute which entries are NEW
/// (not yet in the local library) and should be downloaded.
///
/// Matching logic mirrors SoundCloudClient.findExistingTrack:
/// 1. Match by external_id in track_sources
/// 2. Match by original_path / permalink
/// 3. Fuzzy title+artist match (exact comparison for now)
///
/// Place implementation in: MLM/Services/Sync/PlaylistSyncDiffer.swift
struct Module2_PlaylistSyncDifferTests {

    // MARK: - Helpers

    /// A lightweight remote entry for testing (mirrors RemotePlaylistTrack shape)
    struct TestRemoteEntry: Hashable {
        let externalID: String
        let title: String
        let artist: String
        let originalPath: String
    }

    /// A lightweight local track record for testing
    struct TestLocalTrack: Hashable {
        let id: Int64
        let title: String
        let artist: String
        let originalPath: String?
        let externalIDs: [String]  // from track_sources
    }

    // MARK: - Basic diff

    @Test
    func allNewWhenLocalIsEmpty() {
        let remote: [TestRemoteEntry] = [
            .init(externalID: "yt_1", title: "Song A", artist: "Artist", originalPath: "https://youtube.com/watch?v=1"),
            .init(externalID: "yt_2", title: "Song B", artist: "Artist", originalPath: "https://youtube.com/watch?v=2"),
        ]
        let local: [TestLocalTrack] = []

        let diff = PlaylistSyncDiffer.computeNewEntries(
            remote: remote.map { .init(externalID: $0.externalID, title: $0.title, artist: $0.artist, originalPath: $0.originalPath) },
            local: local.map { .init(id: $0.id, title: $0.title, artist: $0.artist, originalPath: $0.originalPath, externalIDs: $0.externalIDs) }
        )

        #expect(diff.count == 2)
        #expect(diff[0].externalID == "yt_1")
        #expect(diff[1].externalID == "yt_2")
    }

    @Test
    func emptyDiffWhenAllExist() {
        let remote: [TestRemoteEntry] = [
            .init(externalID: "yt_1", title: "Song A", artist: "Artist", originalPath: "https://youtube.com/watch?v=1"),
        ]
        let local: [TestLocalTrack] = [
            .init(id: 100, title: "Song A", artist: "Artist", originalPath: "https://youtube.com/watch?v=1", externalIDs: ["yt_1"]),
        ]

        let diff = PlaylistSyncDiffer.computeNewEntries(
            remote: remote.map { .init(externalID: $0.externalID, title: $0.title, artist: $0.artist, originalPath: $0.originalPath) },
            local: local.map { .init(id: $0.id, title: $0.title, artist: $0.artist, originalPath: $0.originalPath, externalIDs: $0.externalIDs) }
        )

        #expect(diff.isEmpty)
    }

    @Test
    func findsOnlyNewTracks() {
        let remote: [TestRemoteEntry] = [
            .init(externalID: "yt_1", title: "Song A", artist: "Artist", originalPath: "https://youtube.com/watch?v=1"),
            .init(externalID: "yt_2", title: "Song B", artist: "Artist", originalPath: "https://youtube.com/watch?v=2"),
            .init(externalID: "yt_3", title: "Song C", artist: "Artist", originalPath: "https://youtube.com/watch?v=3"),
        ]
        let local: [TestLocalTrack] = [
            .init(id: 100, title: "Song A", artist: "Artist", originalPath: "https://youtube.com/watch?v=1", externalIDs: ["yt_1"]),
            .init(id: 101, title: "Song B", artist: "Artist", originalPath: "https://youtube.com/watch?v=2", externalIDs: ["yt_2"]),
        ]

        let diff = PlaylistSyncDiffer.computeNewEntries(
            remote: remote.map { .init(externalID: $0.externalID, title: $0.title, artist: $0.artist, originalPath: $0.originalPath) },
            local: local.map { .init(id: $0.id, title: $0.title, artist: $0.artist, originalPath: $0.originalPath, externalIDs: $0.externalIDs) }
        )

        #expect(diff.count == 1)
        #expect(diff[0].externalID == "yt_3")
    }

    // MARK: - Match by external_id

    @Test
    func matchesByExternalID() {
        let remote: [TestRemoteEntry] = [
            .init(externalID: "sc_42", title: "Some Title", artist: "Some Artist", originalPath: "https://soundcloud.com/artist/track"),
        ]
        let local: [TestLocalTrack] = [
            .init(id: 200, title: "Different Title", artist: "Different Artist", originalPath: nil, externalIDs: ["sc_42"]),
        ]

        let diff = PlaylistSyncDiffer.computeNewEntries(
            remote: remote.map { .init(externalID: $0.externalID, title: $0.title, artist: $0.artist, originalPath: $0.originalPath) },
            local: local.map { .init(id: $0.id, title: $0.title, artist: $0.artist, originalPath: $0.originalPath, externalIDs: $0.externalIDs) }
        )

        #expect(diff.isEmpty)
    }

    // MARK: - Match by original_path

    @Test
    func matchesByOriginalPath() {
        let remote: [TestRemoteEntry] = [
            .init(externalID: "new_id", title: "Song", artist: "Artist", originalPath: "https://soundcloud.com/artist/song"),
        ]
        let local: [TestLocalTrack] = [
            .init(id: 300, title: "Song", artist: "Artist", originalPath: "https://soundcloud.com/artist/song", externalIDs: []),
        ]

        let diff = PlaylistSyncDiffer.computeNewEntries(
            remote: remote.map { .init(externalID: $0.externalID, title: $0.title, artist: $0.artist, originalPath: $0.originalPath) },
            local: local.map { .init(id: $0.id, title: $0.title, artist: $0.artist, originalPath: $0.originalPath, externalIDs: $0.externalIDs) }
        )

        #expect(diff.isEmpty)
    }

    // MARK: - Match by title+artist

    @Test
    func matchesByTitleAndArtist() {
        let remote: [TestRemoteEntry] = [
            .init(externalID: "unknown", title: "Unique Song Name", artist: "Unique Artist", originalPath: ""),
        ]
        let local: [TestLocalTrack] = [
            .init(id: 400, title: "Unique Song Name", artist: "Unique Artist", originalPath: nil, externalIDs: []),
        ]

        let diff = PlaylistSyncDiffer.computeNewEntries(
            remote: remote.map { .init(externalID: $0.externalID, title: $0.title, artist: $0.artist, originalPath: $0.originalPath) },
            local: local.map { .init(id: $0.id, title: $0.title, artist: $0.artist, originalPath: $0.originalPath, externalIDs: $0.externalIDs) }
        )

        #expect(diff.isEmpty)
    }

    @Test
    func titleMatchIsCaseInsensitive() {
        let remote: [TestRemoteEntry] = [
            .init(externalID: "x", title: "song name", artist: "artist", originalPath: ""),
        ]
        let local: [TestLocalTrack] = [
            .init(id: 500, title: "Song Name", artist: "Artist", originalPath: nil, externalIDs: []),
        ]

        let diff = PlaylistSyncDiffer.computeNewEntries(
            remote: remote.map { .init(externalID: $0.externalID, title: $0.title, artist: $0.artist, originalPath: $0.originalPath) },
            local: local.map { .init(id: $0.id, title: $0.title, artist: $0.artist, originalPath: $0.originalPath, externalIDs: $0.externalIDs) }
        )

        #expect(diff.isEmpty)
    }

    // MARK: - Ordering preservation

    @Test
    func preservesRemoteOrder() {
        let remote: [TestRemoteEntry] = [
            .init(externalID: "c", title: "C", artist: "A", originalPath: ""),
            .init(externalID: "a", title: "A", artist: "A", originalPath: ""),
            .init(externalID: "b", title: "B", artist: "A", originalPath: ""),
        ]
        let local: [TestLocalTrack] = []

        let diff = PlaylistSyncDiffer.computeNewEntries(
            remote: remote.map { .init(externalID: $0.externalID, title: $0.title, artist: $0.artist, originalPath: $0.originalPath) },
            local: local.map { .init(id: $0.id, title: $0.title, artist: $0.artist, originalPath: $0.originalPath, externalIDs: $0.externalIDs) }
        )

        #expect(diff.map(\.externalID) == ["c", "a", "b"])
    }

    // MARK: - Edge cases

    @Test
    func emptyRemoteReturnsEmpty() {
        let diff = PlaylistSyncDiffer.computeNewEntries(
            remote: [],
            local: [.init(id: 1, title: "X", artist: "Y", originalPath: nil, externalIDs: [])]
        )
        #expect(diff.isEmpty)
    }

    @Test
    func bothEmptyReturnsEmpty() {
        let diff = PlaylistSyncDiffer.computeNewEntries(remote: [], local: [])
        #expect(diff.isEmpty)
    }
}
