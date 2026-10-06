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

    private func reel(_ id: String = UUID().uuidString, artist: String = "", title: String = "",
                      state: ReelState = .new) -> ImportedReelRecord {
        ImportedReelRecord(id: id, filePath: "/tmp/\(id).mov", title: title, artist: artist,
                           createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000), state: state)
    }

    @Test func stateGuessesAndDoneAtRoundTrip() async throws {
        let repository = ReelRepository(database: try DatabaseManager.inMemory())
        var record = reel("a", artist: "Fred again..", title: "Delilah", state: .identified)
        record.guessesJSON = "[{\"artist\":\"x\"}]"
        try await repository.save(record)
        let loaded = try #require(try await repository.fetchAll().first)
        #expect(loaded.state == .identified)
        #expect(loaded.guessesJSON == record.guessesJSON)
        #expect(loaded.doneAt == nil)
    }

    @Test func setStateStampsDoneAtAndClearsItAgain() async throws {
        let repository = ReelRepository(database: try DatabaseManager.inMemory())
        try await repository.save(reel("a"))
        try await repository.setState(id: "a", .done, at: Date(timeIntervalSince1970: 5_000))
        var loaded = try #require(try await repository.fetchAll().first)
        #expect(loaded.state == .done)
        #expect(loaded.doneAt != nil)
        try await repository.setState(id: "a", .identified)
        loaded = try #require(try await repository.fetchAll().first)
        #expect(loaded.state == .identified)
        #expect(loaded.doneAt == nil)
    }

    @Test func settingFieldsDerivesTheStateButDoneNeverRegressesUnlessBothAreCleared() async throws {
        let repository = ReelRepository(database: try DatabaseManager.inMemory())
        try await repository.save(reel("a"))
        #expect(try await repository.setFields(id: "a", artist: "Overmono", title: "") == .new)
        #expect(try await repository.setFields(id: "a", artist: "Overmono", title: "So U Kno") == .identified)
        try await repository.setState(id: "a", .done)
        // A different pair, or only one field left: still Done.
        #expect(try await repository.setFields(id: "a", artist: "Bicep", title: "Glue") == .done)
        #expect(try await repository.setFields(id: "a", artist: "Bicep", title: "") == .done)
        let stamp = try #require(try await repository.fetchAll().first?.doneAt)
        #expect(!stamp.isEmpty)
        // Clearing both is the one way back.
        #expect(try await repository.setFields(id: "a", artist: " ", title: "") == .new)
        #expect(try await repository.fetchAll().first?.doneAt == nil)
        #expect(try await repository.setFields(id: "missing", artist: "x", title: "y") == nil)
    }

    @Test func setGuessesStoresAndClears() async throws {
        let repository = ReelRepository(database: try DatabaseManager.inMemory())
        try await repository.save(reel("a"))
        try await repository.setGuesses(id: "a", json: "[]")
        #expect(try await repository.fetchAll().first?.guessesJSON == "[]")
        try await repository.setGuesses(id: "a", json: nil)
        #expect(try await repository.fetchAll().first?.guessesJSON == nil)
    }

    @Test func notDoneCountIgnoresDoneReels() async throws {
        let repository = ReelRepository(database: try DatabaseManager.inMemory())
        #expect(try await repository.notDoneCount() == 0)
        try await repository.save(reel("a"))
        try await repository.save(reel("b", artist: "x", title: "y", state: .identified))
        try await repository.save(reel("c", state: .done))
        #expect(try await repository.notDoneCount() == 2)
    }

    @Test func deleteRemovesOnlyThatReel() async throws {
        let repository = ReelRepository(database: try DatabaseManager.inMemory())
        try await repository.save(reel("a"))
        try await repository.save(reel("b"))
        try await repository.delete(id: "a")
        #expect(try await repository.fetchAll().map(\.id) == ["b"])
    }
}
