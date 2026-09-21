import Foundation
import Testing
@testable import MLM

/// Tests for `PlaylistLinkDiffComputer` — symmetric diff between a remote
/// playlist's track list and a local playlist's current tracks.
struct PlaylistLinkDiffTests {

    // MARK: - Identical sets

    @Test
    func identicalByExternalID_noDifferences() {
        let remote: [PlaylistDifferRemoteEntry] = [
            .init(externalID: "a", title: "A", artist: "X", originalPath: ""),
            .init(externalID: "b", title: "B", artist: "X", originalPath: ""),
        ]
        let local: [PlaylistDifferLocalTrack] = [
            .init(id: 1, title: "A", artist: "X", originalPath: nil, externalIDs: ["a"]),
            .init(id: 2, title: "B", artist: "X", originalPath: nil, externalIDs: ["b"]),
        ]
        let diff = PlaylistLinkDiffComputer.compute(remote: remote, local: local)
        #expect(diff.remoteOnly == 0)
        #expect(diff.localOnly == 0)
        #expect(!diff.hasDifferences)
    }

    @Test
    func identicalByTitleAndArtistOnly_noDifferences() {
        let remote: [PlaylistDifferRemoteEntry] = [
            .init(externalID: "", title: "Song", artist: "Artist", originalPath: ""),
        ]
        let local: [PlaylistDifferLocalTrack] = [
            .init(id: 1, title: "Song", artist: "Artist", originalPath: nil, externalIDs: []),
        ]
        let diff = PlaylistLinkDiffComputer.compute(remote: remote, local: local)
        #expect(diff.remoteOnly == 0)
        #expect(diff.localOnly == 0)
        #expect(!diff.hasDifferences)
    }

    // MARK: - Superset / subset

    @Test
    func remoteSuperset_remoteOnlyGreaterThanZero() {
        let remote: [PlaylistDifferRemoteEntry] = [
            .init(externalID: "a", title: "A", artist: "X", originalPath: ""),
            .init(externalID: "b", title: "B", artist: "X", originalPath: ""),
            .init(externalID: "c", title: "C", artist: "X", originalPath: ""),
        ]
        let local: [PlaylistDifferLocalTrack] = [
            .init(id: 1, title: "A", artist: "X", originalPath: nil, externalIDs: ["a"]),
        ]
        let diff = PlaylistLinkDiffComputer.compute(remote: remote, local: local)
        #expect(diff.remoteOnly == 2)
        #expect(diff.localOnly == 0)
        #expect(diff.hasDifferences)
    }

    @Test
    func localSuperset_localOnlyGreaterThanZero() {
        let remote: [PlaylistDifferRemoteEntry] = [
            .init(externalID: "a", title: "A", artist: "X", originalPath: ""),
        ]
        let local: [PlaylistDifferLocalTrack] = [
            .init(id: 1, title: "A", artist: "X", originalPath: nil, externalIDs: ["a"]),
            .init(id: 2, title: "B", artist: "X", originalPath: nil, externalIDs: []),
            .init(id: 3, title: "C", artist: "X", originalPath: nil, externalIDs: []),
        ]
        let diff = PlaylistLinkDiffComputer.compute(remote: remote, local: local)
        #expect(diff.remoteOnly == 0)
        #expect(diff.localOnly == 2)
        #expect(diff.hasDifferences)
    }

    // MARK: - Disjoint

    @Test
    func disjointSets_bothGreaterThanZero() {
        let remote: [PlaylistDifferRemoteEntry] = [
            .init(externalID: "r1", title: "Remote1", artist: "A", originalPath: ""),
            .init(externalID: "r2", title: "Remote2", artist: "A", originalPath: ""),
        ]
        let local: [PlaylistDifferLocalTrack] = [
            .init(id: 1, title: "Local1", artist: "B", originalPath: nil, externalIDs: ["l1"]),
            .init(id: 2, title: "Local2", artist: "B", originalPath: nil, externalIDs: ["l2"]),
        ]
        let diff = PlaylistLinkDiffComputer.compute(remote: remote, local: local)
        #expect(diff.remoteOnly == 2)
        #expect(diff.localOnly == 2)
        #expect(diff.hasDifferences)
    }

    // MARK: - Edge cases

    @Test
    func emptyRemoteVsNonemptyLocal_localOnlyEqualsLocalCount() {
        let local: [PlaylistDifferLocalTrack] = [
            .init(id: 1, title: "A", artist: "X", originalPath: nil, externalIDs: []),
            .init(id: 2, title: "B", artist: "X", originalPath: nil, externalIDs: []),
            .init(id: 3, title: "C", artist: "X", originalPath: nil, externalIDs: []),
        ]
        let diff = PlaylistLinkDiffComputer.compute(remote: [], local: local)
        #expect(diff.remoteOnly == 0)
        #expect(diff.localOnly == 3)
        #expect(diff.hasDifferences)
    }
}
