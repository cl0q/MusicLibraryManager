import Testing
import GRDB
@testable import MLM

/// Tests for `PlaylistRepository.createSourcePlaylistPreservingExisting`,
/// the SoundCloud import path that must never adopt/clobber an unrelated
/// playlist that happens to share the requested name.
struct PlaylistUniqueNameImportTests {

    // MARK: - Helpers

    private func makeRepo() throws -> (DatabaseQueue, PlaylistRepository) {
        let db = try DatabaseManager.inMemory()
        let repo = PlaylistRepository(database: db)
        return (db, repo)
    }

    // MARK: - Tests

    @Test func reusesRowWhenSourceAndExternalIdMatch() async throws {
        let (_, repo) = try makeRepo()

        let first = try await repo.createSourcePlaylistPreservingExisting(
            name: "Mix", sourceId: 42, externalId: "sc-1"
        )
        let second = try await repo.createSourcePlaylistPreservingExisting(
            name: "Mix", sourceId: 42, externalId: "sc-1"
        )

        #expect(first.id == second.id)
        let all = try await repo.fetchAll()
        let matching = all.filter { $0.name == "Mix" }
        #expect(matching.count == 1)
        // No "Mix 2" row should have appeared.
        #expect(!all.contains(where: { $0.name == "Mix 2" }))
    }

    @Test func suffixesWhenUnrelatedPlaylistHoldsTheName() async throws {
        let (_, repo) = try makeRepo()

        let original = try await repo.create(name: "Mix")
        let imported = try await repo.createSourcePlaylistPreservingExisting(
            name: "Mix", sourceId: 42, externalId: "sc-1"
        )

        #expect(imported.name == "Mix 2")
        #expect(imported.id != original.id)

        // Original is untouched.
        let all = try await repo.fetchAll()
        let orig = all.first(where: { $0.id == original.id })
        #expect(orig?.name == "Mix")
        #expect(orig?.category == original.category)
    }

    @Test func suffixSearchIsCaseInsensitive() async throws {
        let (_, repo) = try makeRepo()

        _ = try await repo.create(name: "mix")
        let imported = try await repo.createSourcePlaylistPreservingExisting(
            name: "Mix", sourceId: 42, externalId: "sc-1"
        )

        #expect(imported.name == "Mix 2")
    }

    @Test func incrementsUntilANameIsFree() async throws {
        let (_, repo) = try makeRepo()

        _ = try await repo.create(name: "Mix")
        _ = try await repo.create(name: "Mix 2")
        let imported = try await repo.createSourcePlaylistPreservingExisting(
            name: "Mix", sourceId: 42, externalId: "sc-1"
        )

        #expect(imported.name == "Mix 3")
    }

    @Test func reimportAfterLocalRenameFollowsExternalIdNotName() async throws {
        let (_, repo) = try makeRepo()

        let first = try await repo.createSourcePlaylistPreservingExisting(
            name: "Mix", sourceId: 42, externalId: "sc-1"
        )
        // Rename the row locally.
        try await repo.rename(id: first.id!, name: "Mix (mine)")

        let second = try await repo.createSourcePlaylistPreservingExisting(
            name: "Mix", sourceId: 42, externalId: "sc-1"
        )

        #expect(second.id == first.id)
        let all = try await repo.fetchAll()
        #expect(!all.contains(where: { $0.name == "Mix 2" }))
    }

    @Test func doesNotAdoptOrMutateTheLikedPlaylist() async throws {
        let (db, repo) = try makeRepo()

        // Seed a liked playlist named "Mix" directly (the public API does not
        // expose liked-playlist creation; this mirrors how the app seeds it).
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO playlists (name, category, is_liked) VALUES ('Mix', 'liked', 1)
            """)
        }
        let likedBefore = try await repo.fetchAll().first(where: { $0.isLiked == 1 })
        #expect(likedBefore != nil)

        let imported = try await repo.createSourcePlaylistPreservingExisting(
            name: "Mix", sourceId: 42, externalId: "sc-1"
        )

        #expect(imported.name == "Mix 2")
        #expect(imported.isLiked == 0)

        let likedAfter = try await repo.fetchAll().first(where: { $0.isLiked == 1 })
        #expect(likedAfter?.id == likedBefore?.id)
        #expect(likedAfter?.name == "Mix")
    }

    @Test func suffixLoopDoesNotAdoptASameNamedSyncedPlaylist() async throws {
        let (_, repo) = try makeRepo()

        // First import occupies "Mix" with a different externalId.
        let first = try await repo.createSourcePlaylistPreservingExisting(
            name: "Mix", sourceId: 42, externalId: "sc-A"
        )
        #expect(first.name == "Mix")

        // Second import must NOT rewrite first's source/external ids; it must
        // create a new "Mix 2" row instead.
        let second = try await repo.createSourcePlaylistPreservingExisting(
            name: "Mix", sourceId: 99, externalId: "sc-B"
        )

        #expect(second.id != first.id)
        #expect(second.name == "Mix 2")

        let firstAfter = try await repo.fetch(id: first.id!)
        #expect(firstAfter?.sourceId == 42)
        #expect(firstAfter?.externalId == "sc-A")
    }

    @Test func returnedRowHasSyncedCategoryAndSourceLinkage() async throws {
        let (_, repo) = try makeRepo()

        let imported = try await repo.createSourcePlaylistPreservingExisting(
            name: "Mix", sourceId: 42, externalId: "sc-1"
        )

        #expect(imported.category == "synced")
        #expect(imported.isLiked == 0)
        #expect(imported.sourceId == 42)
        #expect(imported.externalId == "sc-1")
    }
}
