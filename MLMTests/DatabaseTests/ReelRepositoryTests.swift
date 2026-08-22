import Foundation
import GRDB
import Testing
@testable import MLM

@Suite("ReelRepositoryTests")
struct ReelRepositoryTests {
    @Test func additiveMigrationCreatesImportedReelsTable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.read { db in
            #expect(try db.tableExists("imported_reels"))
            let columns = try db.columns(in: "imported_reels").map(\.name)
            #expect(columns.contains("file_path"))
            #expect(columns.contains("created_at"))
            #expect(columns.contains("updated_at"))
        }
    }

    @Test func reelQueueRoundTripsAndUpdatesByStableID() async throws {
        let database = try DatabaseManager.inMemory()
        let repository = ReelRepository(database: database)
        let id = UUID().uuidString
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let updatedAt = Date(timeIntervalSince1970: 2_000)

        try await repository.save(
            ImportedReelRecord(
                id: id,
                filePath: "/tmp/reel.mov",
                title: "Original title",
                artist: "Original artist",
                createdAt: createdAt,
                updatedAt: createdAt
            )
        )
        try await repository.save(
            ImportedReelRecord(
                id: id,
                filePath: "/tmp/reel.mov",
                title: "Identified title",
                artist: "Identified artist",
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        )

        let reels = try await repository.fetchAll()
        #expect(reels.count == 1)
        #expect(reels.first?.title == "Identified title")
        #expect(reels.first?.artist == "Identified artist")
        #expect(reels.first?.createdAt == createdAt)
        #expect(reels.first?.updatedAt == updatedAt)
    }
}
