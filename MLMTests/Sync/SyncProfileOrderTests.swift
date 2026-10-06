import Foundation
import GRDB
import Testing
@testable import MLM

/// The order of the sidebar's Sync section (IMP-106): repository, pure move, drop cells and the
/// undoable `Reorder Sync Profiles`.
@Suite("SyncProfileOrderTests")
@MainActor
struct SyncProfileOrderTests {

    // MARK: Pure move

    @Test func movesBeforeATargetAndToTheEnd() {
        let order: [Int64] = [1, 2, 3, 4]
        #expect(SyncProfileOrder.moved([4], before: 2, in: order) == [1, 4, 2, 3])
        #expect(SyncProfileOrder.moved([1], before: nil, in: order) == [2, 3, 4, 1])
        #expect(SyncProfileOrder.moved([3, 1], before: 2, in: order) == [3, 1, 2, 4])
    }

    @Test func aProfileIsNeverPlacedBeforeItselfAndNoMoveChangesNothing() {
        let order: [Int64] = [1, 2, 3]
        #expect(SyncProfileOrder.moved([2], before: 2, in: order) == order)
        #expect(SyncProfileOrder.moved([9], before: 1, in: order) == order)
        #expect(SyncProfileOrder.moved([1], before: 2, in: order) == order, "already there")
    }

    // MARK: Repository

    private func names(_ sync: SyncRepository) async throws -> [String] {
        try await sync.fetchAll().map(\.name)
    }

    @Test func newAndDuplicatedProfilesGoLastAndTheOrderIsStored() async throws {
        let env = try await SyncTestEnv()
        let a = try await env.sync.create(name: "B Player", outputFolder: "/d/1")
        let b = try await env.sync.create(name: "A Player", outputFolder: "/d/2")
        #expect(try await names(env.sync) == ["B Player", "A Player"], "creation order, not name order")
        let copy = try await env.sync.duplicate(id: a.id!)
        #expect(try await env.sync.profileOrder() == [a.id!, b.id!, copy.id!])

        try await env.sync.setProfileOrder([b.id!, copy.id!, a.id!])
        #expect(try await env.sync.profileOrder() == [b.id!, copy.id!, a.id!])
        // A profile missing from the list follows; unknown ids are ignored.
        try await env.sync.setProfileOrder([copy.id!, 999])
        #expect(try await env.sync.profileOrder() == [copy.id!, b.id!, a.id!])
    }

    // MARK: Drop cells

    private let context = DropContext(libraryID: "lib", isLibraryOpen: true, offlineVolumeName: nil)

    private func profileDrag(_ ids: Int64...) -> DropContent {
        .playlists(ids.map { PlaylistDragItem.syncProfile($0, libraryId: "lib") })
    }

    @Test func aProfileDroppedBetweenRowsOrOnARowMoves() {
        #expect(DropRules.decide(profileDrag(3), onto: .syncProfileOrder(before: 1), context: context)
                == .moveSyncProfiles([3], before: 1))
        #expect(DropRules.decide(profileDrag(3), onto: .syncProfileOrder(before: nil), context: context)
                == .moveSyncProfiles([3], before: nil))
        #expect(DropRules.decide(profileDrag(3), onto: .syncProfile(id: 2, name: "Car"), context: context)
                == .moveSyncProfiles([3], before: 2))
    }

    @Test func aProfileDragGoesNowhereElse() {
        let targets: [DropTarget] = [
            .sidebarPlaylist(id: 1, name: "Mix"), .playlistsSection, .player,
            .playlistOrder(folderID: nil, before: nil), .playlistFolder(id: 1, name: "F"),
            .playlistTable(id: 1, name: "Mix", sortedBy: nil), .window,
        ]
        for target in targets {
            #expect(DropRules.decide(profileDrag(3), onto: target, context: context) == .refuse(nil), "\(target)")
        }
    }

    @Test func playlistsAndTracksAreNotTakenBetweenProfileRows() {
        let playlists = DropContent.playlists([PlaylistDragItem(playlistId: 4, libraryId: "lib")])
        #expect(DropRules.decide(playlists, onto: .syncProfileOrder(before: 1), context: context) == .refuse(nil))
        let tracks = DropContent.tracks(TrackDragPayload(items: [TrackDragItem(trackId: 1, libraryId: "lib")]))
        #expect(DropRules.decide(tracks, onto: .syncProfileOrder(before: 1), context: context) == .refuse(nil))
        // A playlist on a profile row still adds it (unchanged).
        #expect(DropRules.decide(playlists, onto: .syncProfile(id: 2, name: "Car"), context: context)
                == .addPlaylistsToSyncProfile([4], profileID: 2, profileName: "Car"))
    }

    @Test func theHoverRingFollowsTheMatrix() {
        #expect(DropRules.accepts(.playlists, on: .syncProfileOrder(before: nil), context: context))
        #expect(!DropRules.accepts(.tracks, on: .syncProfileOrder(before: nil), context: context))
        #expect(!DropRules.accepts(.files, on: .syncProfileOrder(before: nil), context: context))
    }

    @Test func aProfileDragRoundTripsAndOldPayloadsStillDecode() throws {
        let item = PlaylistDragItem.syncProfile(7, libraryId: "lib")
        let decoded = try JSONDecoder().decode(PlaylistDragItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.syncProfileId == 7)
        let old = try JSONDecoder().decode(PlaylistDragItem.self, from: Data(#"{"playlistId":5,"libraryId":"lib"}"#.utf8))
        #expect(old.syncProfileId == nil && old.playlistId == 5)
    }

    // MARK: Undo

    @Test func reorderIsOneUndoStepWithItsOwnWords() async throws {
        let env = try await SyncTestEnv()
        let a = try await env.sync.create(name: "A", outputFolder: "/d/1")
        let b = try await env.sync.create(name: "B", outputFolder: "/d/2")
        let c = try await env.sync.create(name: "C", outputFolder: "/d/3")

        await env.edits.moveSyncProfiles([c.id!], before: a.id!)
        #expect(try await env.sync.profileOrder() == [c.id!, a.id!, b.id!])
        #expect(env.status.message?.text == "Moved “C”")
        #expect(env.undoManager.undoActionName == "Reorder Sync Profiles")

        env.undoManager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await env.sync.profileOrder() == [a.id!, b.id!, c.id!])
        env.undoManager.redo()
        await env.undo.waitUntilIdle()
        #expect(try await env.sync.profileOrder() == [c.id!, a.id!, b.id!])
    }

    @Test func aMoveThatChangesNothingIsNoStep() async throws {
        let env = try await SyncTestEnv()
        let a = try await env.sync.create(name: "A", outputFolder: "/d/1")
        let b = try await env.sync.create(name: "B", outputFolder: "/d/2")
        await env.edits.moveSyncProfiles([a.id!], before: b.id!)
        #expect(!env.undoManager.canUndo)
    }
}
