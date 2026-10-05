import Foundation
import Testing
@testable import MLM

/// Where tracks dropped between the rows of a playlist go (D-PLD-REORDER, D-PLD-INSERT,
/// UC-TABLE-05) and the fractional positions they get — pure.
@Suite("Playlist drop plan")
struct PlaylistDropPlanTests {
    private let order: [Int64] = [10, 20, 30, 40, 50]

    private func plan(_ ids: [Int64], at index: Int, shown: [Int64]? = nil, playlistOrder: Bool = true,
                      filtered: Bool = false) -> PlaylistDropPlan? {
        PlaylistDropPlan.make(trackIDs: ids, playlistOrder: order, displayRows: shown ?? order, insertionIndex: index,
                              isPlaylistOrder: playlistOrder, isFiltered: filtered)
    }

    @Test func rowsOfThePlaylistReorder() throws {
        let moved = try #require(plan([40, 50], at: 1))
        #expect(moved.kind == .reorder)
        #expect(moved.beforeTrackID == 20)
        #expect(moved.apply(to: order) == [10, 40, 50, 20, 30])
        let toEnd = try #require(plan([10], at: 5))
        #expect(toEnd.beforeTrackID == nil)
        #expect(toEnd.apply(to: order) == [20, 30, 40, 50, 10])
    }

    @Test func droppingRowsWhereTheyAreDoesNothing() {
        #expect(plan([20, 30], at: 1) == nil)
        #expect(plan([20, 30], at: 3) == nil)
    }

    @Test func reorderIsOffWhileSortedOrFiltered() {
        #expect(plan([40], at: 0, playlistOrder: false) == nil)
        #expect(plan([40], at: 0, shown: [10, 40], filtered: true) == nil)
    }

    @Test func tracksFromElsewhereGoInAtTheLine() throws {
        let inserted = try #require(plan([99, 98], at: 2))
        #expect(inserted.kind == .insert)
        #expect(inserted.apply(to: order) == [10, 20, 99, 98, 30, 40, 50])
        // A member among them moves there too.
        let mixed = try #require(plan([99, 50], at: 0))
        #expect(mixed.kind == .insert)
        #expect(mixed.apply(to: order) == [99, 50, 10, 20, 30, 40])
    }

    @Test func whileSortedTracksFromElsewhereAreAppended() throws {
        let appended = try #require(plan([99], at: 0, playlistOrder: false))
        #expect(appended.kind == .append)
        #expect(appended.beforeTrackID == nil)
    }

    @Test func aFilteredTableMapsItsLineIntoThePlaylistOrder() throws {
        // Shown: 20 and 40 (a search hides the rest); dropped between them.
        let inserted = try #require(plan([99], at: 1, shown: [20, 40], filtered: true))
        #expect(inserted.beforeTrackID == 40)
        #expect(PlaylistDropPlan.targetIndex(insertionIndex: 2, displayRows: [20, 40], playlistOrder: order) == 4)
        #expect(PlaylistDropPlan.targetIndex(insertionIndex: 0, displayRows: [], playlistOrder: order) == 5)
    }

    @Test func placementsLandBetweenTheNeighboursInDragOrder() {
        let entries: [(trackID: Int64, position: String?)] = [(10, "a0"), (20, "a1"), (30, "a2")]
        let placements = PlaylistPlacement.positions(for: [99, 98], before: 20, in: entries)
        #expect(placements.map(\.trackId) == [99, 98])
        let positions = placements.map(\.position)
        #expect(positions[0] > "a0" && positions[0] < "a1")
        #expect(positions[1] > positions[0] && positions[1] < "a1")
        // At the end, after the moving member is taken out.
        let end = PlaylistPlacement.positions(for: [30], before: nil, in: entries)
        #expect(end[0].position > "a1")
    }

    @Test func manyTracksBetweenTwoNeighboursGetDistinctIncreasingPositions() {
        // `FractionalIndexer` returns its left bound for (`a0|V`, `a1`); a drop of several
        // tracks must still give each its own position, in drag order.
        let entries: [(trackID: Int64, position: String?)] = [(10, "a0"), (20, "a1")]
        let positions = PlaylistPlacement.positions(for: [1, 2, 3, 4, 5, 6], before: 20, in: entries).map(\.position)
        #expect(positions == positions.sorted())
        #expect(Set(positions).count == positions.count)
        #expect(positions.allSatisfy { $0 > "a0" && $0 < "a1" })
        #expect(PlaylistPlacement.strictlyBetween("a0|V", "a1") > "a0|V")
    }
}
