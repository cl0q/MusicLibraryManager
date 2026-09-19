import Foundation
import Testing
@testable import MLM

struct SearchResultsMergerTests {

    private func makeTrack(id: Int64, title: String) -> Track {
        var t = Track(artist: "A", album: "B", title: title, format: "mp3",
                      originalPath: "/\(title).mp3")
        t.id = id
        t.dateAdded = "2024-01-01T00:00:00Z"
        return t
    }

    // MARK: - Ordering

    @Test func contextTracksComeFirst() async throws {
        let context = [makeTrack(id: 1, title: "C1")]
        let library = [makeTrack(id: 2, title: "L1")]
        let remote  = [makeTrack(id: 3, title: "R1")]

        let merged = SearchResultsMerger.merge(
            contextTracks: context,
            libraryTracks: library,
            remoteTracks: remote
        )

        #expect(merged.map(\.title) == ["C1", "L1", "R1"])
    }

    @Test func preservesContextOrder() async throws {
        let context = [
            makeTrack(id: 10, title: "First"),
            makeTrack(id: 20, title: "Second")
        ]
        let merged = SearchResultsMerger.merge(
            contextTracks: context,
            libraryTracks: [],
            remoteTracks: []
        )
        #expect(merged.map(\.title) == ["First", "Second"])
    }

    // MARK: - Dedup by id

    @Test func dedupsLibraryTracksAlreadyInContext() async throws {
        let context = [makeTrack(id: 1, title: "Shared")]
        let library = [makeTrack(id: 1, title: "Shared")]
        let merged = SearchResultsMerger.merge(
            contextTracks: context,
            libraryTracks: library,
            remoteTracks: []
        )
        #expect(merged.count == 1)
        #expect(merged[0].title == "Shared")
    }

    @Test func dedupsRemoteTracksAlreadyInLibrary() async throws {
        let library = [makeTrack(id: 5, title: "Dup")]
        let remote  = [makeTrack(id: 5, title: "Dup")]
        let merged = SearchResultsMerger.merge(
            contextTracks: [],
            libraryTracks: library,
            remoteTracks: remote
        )
        #expect(merged.count == 1)
    }

    // MARK: - Empty inputs

    @Test func emptyInputsReturnsEmpty() async throws {
        let merged = SearchResultsMerger.merge(
            contextTracks: [],
            libraryTracks: [],
            remoteTracks: []
        )
        #expect(merged.isEmpty)
    }

    @Test func onlyLibraryTracks() async throws {
        let library = [makeTrack(id: 1, title: "L")]
        let merged = SearchResultsMerger.merge(
            contextTracks: [],
            libraryTracks: library,
            remoteTracks: []
        )
        #expect(merged.count == 1)
        #expect(merged[0].title == "L")
    }

    // MARK: - Context enum

    @Test func contextEquatable() {
        #expect(SearchResultsMerger.Context.library == SearchResultsMerger.Context.library)
        #expect(SearchResultsMerger.Context.playlist == SearchResultsMerger.Context.playlist)
        #expect(SearchResultsMerger.Context.other == SearchResultsMerger.Context.other)
        #expect(SearchResultsMerger.Context.library != SearchResultsMerger.Context.playlist)
    }
}
