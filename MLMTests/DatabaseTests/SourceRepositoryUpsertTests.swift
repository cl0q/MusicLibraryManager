import Testing
import GRDB
@testable import MLM

struct SourceRepositoryUpsertTests {

    // MARK: - Helpers

    private func makeRepo() throws -> (DatabaseQueue, SourceRepository) {
        let db = try DatabaseManager.inMemory()
        let repo = SourceRepository(database: db)
        return (db, repo)
    }

    // MARK: - Tests

    @Test func upsertReturnsSameIdOnRepeatedCalls() async throws {
        let (_, repo) = try makeRepo()

        let first = try await repo.upsert(name: "soundcloud", userId: "42")
        let second = try await repo.upsert(name: "soundcloud", userId: "42")
        let third = try await repo.upsert(name: "soundcloud", userId: "42")

        #expect(first.id != nil)
        #expect(first.id == second.id)
        #expect(second.id == third.id)
    }

    @Test func upsertDoesNotCreateDuplicateSourceRows() async throws {
        let (_, repo) = try makeRepo()

        _ = try await repo.upsert(name: "soundcloud", userId: "42")
        _ = try await repo.upsert(name: "soundcloud", userId: "42")
        _ = try await repo.upsert(name: "soundcloud", userId: "42")

        let all = try await repo.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.name == "soundcloud")
        #expect(all.first?.userId == "42")
    }

    @Test func upsertIdIsNotPollutedByPriorInsertsOnTheSameConnection() async throws {
        let (db, sourceRepo) = try makeRepo()
        let playlistRepo = PlaylistRepository(database: db)

        // Seed the source row first.
        let original = try await sourceRepo.upsert(name: "soundcloud", userId: "42")

        // Leave db.lastInsertedRowID pointing at unrelated rows by inserting
        // other records after the source row was created.
        _ = try await playlistRepo.create(name: "Mix A")
        _ = try await playlistRepo.create(name: "Mix B")
        _ = try await playlistRepo.create(name: "Mix C")

        // Capture the stale rowid the buggy implementation would have returned.
        let staleRowId = try await db.read { db in
            db.lastInsertedRowID
        }
        // Sanity: the stale rowid must differ from the source's true id,
        // otherwise this test cannot distinguish the bug from correct behaviour.
        #expect(staleRowId != original.id)

        // Re-upsert the same source. The buggy implementation would return
        // staleRowId instead of the source's true id.
        let again = try await sourceRepo.upsert(name: "soundcloud", userId: "42")

        #expect(again.id == original.id)
        #expect(again.id != staleRowId)
    }

    @Test func upsertDistinguishesDifferentUserIds() async throws {
        let (_, repo) = try makeRepo()

        let a = try await repo.upsert(name: "soundcloud", userId: "42")
        let b = try await repo.upsert(name: "soundcloud", userId: "99")

        #expect(a.id != b.id)
        let all = try await repo.fetchAll()
        #expect(all.count == 2)
    }

    @Test func upsertDistinguishesDifferentNames() async throws {
        let (_, repo) = try makeRepo()

        let a = try await repo.upsert(name: "soundcloud", userId: "42")
        let b = try await repo.upsert(name: "spotify", userId: "42")

        #expect(a.id != b.id)
        let all = try await repo.fetchAll()
        #expect(all.count == 2)
    }

    @Test func upsertPreservesEnabledStateOnExistingRow() async throws {
        let (_, repo) = try makeRepo()

        let created = try await repo.upsert(name: "soundcloud", userId: "42")
        #expect(created.enabled == 1)

        try await repo.toggleEnabled(id: created.id!)
        let flipped = try await repo.fetch(id: created.id!)
        #expect(flipped?.enabled == 0)

        let re = try await repo.upsert(name: "soundcloud", userId: "42")
        #expect(re.id == created.id)
        #expect(re.enabled == 0)
    }
}
