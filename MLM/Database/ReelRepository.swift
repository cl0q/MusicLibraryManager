import Foundation
import GRDB

/// Durable storage for the Reels identification queue.
final class ReelRepository: Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func fetchAll() async throws -> [ImportedReelRecord] {
        try await database.read { db in
            try ImportedReelRecord
                .order(ImportedReelRecord.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    func save(_ reel: ImportedReelRecord) async throws {
        try await database.write { db in
            try reel.save(db)
        }
    }

    func delete(id: String) async throws {
        _ = try await database.write { db in
            try ImportedReelRecord.deleteOne(db, key: id)
        }
    }
}
