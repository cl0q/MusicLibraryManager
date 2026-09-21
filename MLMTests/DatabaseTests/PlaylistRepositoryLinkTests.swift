import Testing
import GRDB
@testable import MLM

/// Tests for `PlaylistRepository.updateSourceLink(id:sourceId:externalId:)`
/// — the atomic two-column write used by the "Link Source" flow.
struct PlaylistRepositoryLinkTests {

    // MARK: - Helpers

    private func makeRepo() throws -> (DatabaseQueue, PlaylistRepository, SourceRepository) {
        let db = try DatabaseManager.inMemory()
        let playlistRepo = PlaylistRepository(database: db)
        let sourceRepo = SourceRepository(database: db)
        return (db, playlistRepo, sourceRepo)
    }

    // MARK: - Tests

    @Test func updateSourceLink_setsBothColumns() async throws {
        let (_, playlistRepo, sourceRepo) = try makeRepo()
        let pl = try await playlistRepo.create(name: "Link Test")
        let source = try await sourceRepo.upsert(name: "youtube", userId: "local")

        try await playlistRepo.updateSourceLink(
            id: pl.id!,
            sourceId: source.id,
            externalId: "https://youtube.com/playlist?list=PLtest"
        )

        let fetched = try await playlistRepo.fetch(id: pl.id!)
        #expect(fetched?.sourceId == source.id)
        #expect(fetched?.externalId == "https://youtube.com/playlist?list=PLtest")
    }

    @Test func updateSourceLink_withNils_clearsBoth() async throws {
        let (_, playlistRepo, sourceRepo) = try makeRepo()
        let pl = try await playlistRepo.create(name: "Clear Test")
        let source = try await sourceRepo.upsert(name: "youtube", userId: "local")

        // First set values.
        try await playlistRepo.updateSourceLink(
            id: pl.id!,
            sourceId: source.id,
            externalId: "https://youtube.com/playlist?list=PLtest"
        )
        // Then clear them.
        try await playlistRepo.updateSourceLink(
            id: pl.id!,
            sourceId: nil,
            externalId: nil
        )

        let fetched = try await playlistRepo.fetch(id: pl.id!)
        #expect(fetched?.sourceId == nil)
        #expect(fetched?.externalId == nil)
    }
}
