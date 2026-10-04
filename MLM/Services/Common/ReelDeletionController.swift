import Foundation

struct ReelDeletionFailure: Sendable {
    let reel: ImportedReel
    let error: any Error
}

struct ReelDeletionOutcome: Sendable {
    let deletedIDs: [UUID]
    let failed: [ReelDeletionFailure]
}

enum ReelDeletionController {
    static func delete(
        _ reels: [ImportedReel],
        using deleteOne: (String) async throws -> Void
    ) async -> ReelDeletionOutcome {
        var deletedIDs: [UUID] = []
        var failed: [ReelDeletionFailure] = []
        for reel in reels {
            do {
                try await deleteOne(reel.id.uuidString)
                deletedIDs.append(reel.id)
            } catch {
                failed.append(ReelDeletionFailure(reel: reel, error: error))
            }
        }
        return ReelDeletionOutcome(deletedIDs: deletedIDs, failed: failed)
    }
}
