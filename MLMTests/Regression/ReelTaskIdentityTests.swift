import Foundation
import Testing
@testable import MLM

@Suite("LOGIC-002 reel task identity")
struct ReelTaskIdentityTests {

    @Test func completionUpdatesTargetAfterEarlierReelIsDeleted() {
        let first = ImportedReel(
            id: UUID(),
            fileURL: URL(fileURLWithPath: "/reels/first.mov"),
            title: "First",
            artist: "Artist"
        )
        let targetID = UUID()
        let target = ImportedReel(
            id: targetID,
            fileURL: URL(fileURLWithPath: "/reels/target.mov"),
            title: "Target",
            artist: "Artist"
        )
        let last = ImportedReel(
            id: UUID(),
            fileURL: URL(fileURLWithPath: "/reels/last.mov"),
            title: "Last",
            artist: "Artist"
        )
        var reels = [first, target, last]

        reels.removeFirst()
        let updated = ReelsInboxView.updateImportedReel(id: targetID, in: &reels) {
            $0.matchedTitle = "Recognized"
            $0.matchFailed = false
        }

        #expect(updated?.id == targetID)
        #expect(reels[0].id == targetID)
        #expect(reels[0].matchedTitle == "Recognized")
        #expect(reels[1].id == last.id)
        #expect(reels[1].matchedTitle == nil)
    }

    @Test func completionForDeletedReelDoesNotMutateAnotherReel() {
        let deletedID = UUID()
        let deleted = ImportedReel(
            id: deletedID,
            fileURL: URL(fileURLWithPath: "/reels/deleted.mov"),
            title: "Deleted",
            artist: "Artist"
        )
        let survivor = ImportedReel(
            id: UUID(),
            fileURL: URL(fileURLWithPath: "/reels/survivor.mov"),
            title: "Survivor",
            artist: "Artist"
        )
        var reels = [deleted, survivor]

        reels.removeFirst()
        let updated = ReelsInboxView.updateImportedReel(id: deletedID, in: &reels) {
            $0.matchFailed = true
        }

        #expect(updated == nil)
        #expect(reels.count == 1)
        #expect(reels[0].id == survivor.id)
        #expect(reels[0].matchFailed == false)
    }
}
