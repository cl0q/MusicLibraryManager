import Foundation
import Testing

@testable import MLM

@MainActor
struct ReelDeletionTests {

    private func makeReel(id: UUID = UUID()) -> ImportedReel {
        ImportedReel(
            id: id,
            fileURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).mp4"),
            title: "Reel \(id.uuidString.prefix(4))",
            artist: "Artist"
        )
    }

    @Test func allSucceed_returnsAllDeletedIDs_preservingOrder() async throws {
        let reels = (0..<3).map { _ in makeReel() }
        var calls: [String] = []

        let outcome = await ReelDeletionController.delete(reels) { id in
            calls.append(id)
        }

        #expect(outcome.failed.isEmpty)
        #expect(outcome.deletedIDs == reels.map(\.id))
        #expect(calls == reels.map { $0.id.uuidString })
    }

    @Test func middleThrows_failedContainsOnlyThatReel_othersDeleted() async throws {
        let reels = (0..<3).map { _ in makeReel() }
        let failingID = reels[1].id.uuidString
        struct Boom: Error {}

        let outcome = await ReelDeletionController.delete(reels) { id in
            if id == failingID { throw Boom() }
        }

        #expect(outcome.deletedIDs == [reels[0].id, reels[2].id])
        #expect(outcome.failed.count == 1)
        #expect(outcome.failed.first?.reel.id == reels[1].id)
        #expect(outcome.failed.first?.error is Boom)
    }

    @Test func allThrow_deletedEmpty_allFailed() async throws {
        let reels = (0..<2).map { _ in makeReel() }
        struct Always: Error {}

        let outcome = await ReelDeletionController.delete(reels) { _ in
            throw Always()
        }

        #expect(outcome.deletedIDs.isEmpty)
        #expect(outcome.failed.count == reels.count)
        #expect(outcome.failed.map(\.reel.id) == reels.map(\.id))
    }

    @Test func emptyInput_noCalls_emptyOutcome() async throws {
        var called = false
        let outcome = await ReelDeletionController.delete([]) { _ in called = true }

        #expect(!called)
        #expect(outcome.deletedIDs.isEmpty)
        #expect(outcome.failed.isEmpty)
    }
}
