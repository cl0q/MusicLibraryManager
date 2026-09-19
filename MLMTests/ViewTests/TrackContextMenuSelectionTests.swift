import Testing
import Foundation
@testable import MLM

@Suite("TrackContextMenuSelectionTests")
struct TrackContextMenuSelectionTests {

    private func makeTrack(id: Int64?, organizedPath: String? = nil) -> Track {
        var track = Track(
            artist: "Artist",
            album: "Album",
            title: "Track \(id.map(String.init) ?? "nil")",
            format: "m4a",
            originalPath: "source://track"
        )
        track.id = id
        track.organizedPath = organizedPath
        return track
    }

    private func filterSelected(tracks: [Track], selectedIDs: Set<Int64>) -> [Track] {
        tracks.filter { track in
            guard let id = track.id else { return false }
            return selectedIDs.contains(id)
        }
    }

    // MARK: - Filter semantics

    @Test func filter_returnsOnlyTracksWhoseIdIsInSet() {
        let tracks = (1...5).map { makeTrack(id: Int64($0)) }
        let selectedIDs: Set<Int64> = [2, 4]

        let result = filterSelected(tracks: tracks, selectedIDs: selectedIDs)

        #expect(result.count == 2)
        #expect(result.map(\.id) == [2, 4])
    }

    @Test func filter_excludesTracksWithNilId() {
        let tracks = [
            makeTrack(id: 1),
            makeTrack(id: nil),
            makeTrack(id: 3),
            makeTrack(id: nil),
        ]
        let selectedIDs: Set<Int64> = [1, 3]

        let result = filterSelected(tracks: tracks, selectedIDs: selectedIDs)

        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.id != nil })
    }

    @Test func filter_emptySelectionYieldsEmptyArray() {
        let tracks = (1...10).map { makeTrack(id: Int64($0)) }
        let selectedIDs: Set<Int64> = []

        let result = filterSelected(tracks: tracks, selectedIDs: selectedIDs)

        #expect(result.isEmpty)
    }

    @Test func filter_singleVsMultiSelectionMatchesCountSuffixThreshold() {
        let tracks = (1...3).map { makeTrack(id: Int64($0)) }

        let single = filterSelected(tracks: tracks, selectedIDs: [1])
        #expect(single.count == 1)
        #expect(!(single.count > 1))

        let multi = filterSelected(tracks: tracks, selectedIDs: [1, 2, 3])
        #expect(multi.count == 3)
        #expect(multi.count > 1)
    }

    @Test func filter_largeArrayPreservesOrder() {
        let tracks = (1...1000).map { makeTrack(id: Int64($0)) }
        let selectedIDs: Set<Int64> = [100, 500, 999]

        let result = filterSelected(tracks: tracks, selectedIDs: selectedIDs)

        #expect(result.map(\.id) == [100, 500, 999])
    }
}
