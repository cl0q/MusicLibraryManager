import Testing
import GRDB
@testable import MLM

/// Tests for `SourceRepository.fetchExternalIDs(trackIds:)` — the batch
/// external-ID lookup used by the "Link Source" diff.
struct SourceRepositoryExternalIDsTests {

    // MARK: - Helpers

    private func makeRepo() throws -> (DatabaseQueue, SourceRepository) {
        let db = try DatabaseManager.inMemory()
        let repo = SourceRepository(database: db)
        return (db, repo)
    }

    /// Insert a minimal track row so track_sources can reference it.
    private func seedTrack(db: DatabaseQueue, id: Int64, title: String) async throws {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, date_added)
                VALUES (?, 'Artist', 'Artist', 'Album', ?, 'mp3', '/tmp/\(id).mp3', '2025-01-01T00:00:00Z')
            """, arguments: [id, title])
        }
    }

    // MARK: - Tests

    @Test func fetchExternalIDs_returnsLinkedIdsForBothTracks() async throws {
        let (db, repo) = try makeRepo()
        let source = try await repo.upsert(name: "youtube", userId: "local")
        guard let sourceId = source.id else {
            Issue.record("source.id is nil")
            return
        }

        try await seedTrack(db: db, id: 100, title: "Track A")
        try await seedTrack(db: db, id: 200, title: "Track B")

        try await repo.linkTrackToSource(trackId: 100, sourceId: sourceId, externalId: "yt_aaa")
        try await repo.linkTrackToSource(trackId: 200, sourceId: sourceId, externalId: "yt_bbb")

        let result = try await repo.fetchExternalIDs(trackIds: [100, 200])
        #expect(result[100] == ["yt_aaa"])
        #expect(result[200] == ["yt_bbb"])
    }

    @Test func fetchExternalIDs_omitsUnlinkedTracks() async throws {
        let (db, repo) = try makeRepo()
        let source = try await repo.upsert(name: "youtube", userId: "local")
        guard let sourceId = source.id else {
            Issue.record("source.id is nil")
            return
        }

        try await seedTrack(db: db, id: 100, title: "Linked")
        try await seedTrack(db: db, id: 200, title: "Unlinked")

        try await repo.linkTrackToSource(trackId: 100, sourceId: sourceId, externalId: "yt_aaa")

        let result = try await repo.fetchExternalIDs(trackIds: [100, 200])
        #expect(result[100] == ["yt_aaa"])
        #expect(result[200] == nil, "Unlinked track should not appear in the result")
    }

    @Test func fetchExternalIDs_emptySetReturnsEmptyDict() async throws {
        let (_, repo) = try makeRepo()
        let result = try await repo.fetchExternalIDs(trackIds: [])
        #expect(result.isEmpty)
    }
}
