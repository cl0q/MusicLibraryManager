import Foundation
import GRDB
import Testing
@testable import MLM

@Suite("DiscoveryReviewTrashTests")
struct DiscoveryReviewTrashTests {
    private func makeService(
        database: DatabaseQueue,
        trackRepository: TrackRepository,
        trashDir: URL,
        dbDeleteThrows: Bool = false
    ) -> DiscoveryReviewService {
        let configRepo = ConfigRepository(database: database)
        let trashFile: @Sendable (URL) throws -> URL = { url in
            let dest = trashDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
        let deleteFromDatabase: @Sendable (Int64) async throws -> Void = { id in
            if dbDeleteThrows {
                throw CocoaError(.fileWriteNoPermission)
            }
            try await trackRepository.delete(id: id)
        }
        return DiscoveryReviewService(
            trackRepository: trackRepository,
            configRepository: configRepo,
            trashFile: trashFile,
            deleteFromDatabase: deleteFromDatabase
        )
    }

    private func insertTrackWithFile(
        _ database: DatabaseQueue,
        fileURL: URL
    ) async throws -> Track {
        try await database.write { db in
            var track = Track(
                artist: "Artist",
                album: "Album",
                title: "Song",
                format: "flac",
                originalPath: fileURL.path
            )
            try track.insert(db)
            return track
        }
    }

    @Test func deleteMovesFileToTrashAndRecordsRecovery() async throws {
        let database = try DatabaseManager.inMemory()
        let trackRepo = TrackRepository(database: database)
        let trashDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trashDir) }

        let fileDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
        let fileURL = fileDir.appendingPathComponent("test.flac")
        try "audio data".write(to: fileURL, atomically: true, encoding: .utf8)

        let track = try await insertTrackWithFile(database, fileURL: fileURL)
        let service = makeService(database: database, trackRepository: trackRepo, trashDir: trashDir)

        try await service.delete(track: track)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let trashedFile = trashDir.appendingPathComponent("test.flac")
        #expect(FileManager.default.fileExists(atPath: trashedFile.path))
        #expect(service.lastDeleteRecovery?.trackID == track.id)
        #expect(service.lastDeleteRecovery?.originalURL == fileURL)
        #expect(service.lastDeleteRecovery?.trashedURL == trashedFile)
    }

    @Test func deleteRecordsRecoveryWhenDBDeleteFails() async throws {
        let database = try DatabaseManager.inMemory()
        let trackRepo = TrackRepository(database: database)
        let trashDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trashDir) }

        let fileDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
        let fileURL = fileDir.appendingPathComponent("recover.flac")
        try "audio data".write(to: fileURL, atomically: true, encoding: .utf8)

        let track = try await insertTrackWithFile(database, fileURL: fileURL)
        let service = makeService(
            database: database,
            trackRepository: trackRepo,
            trashDir: trashDir,
            dbDeleteThrows: true
        )

        do {
            try await service.delete(track: track)
            Issue.record("Expected error to propagate")
        } catch {
            // expected
        }

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let trashedFile = trashDir.appendingPathComponent("recover.flac")
        #expect(FileManager.default.fileExists(atPath: trashedFile.path))
        #expect(service.lastDeleteRecovery?.trackID == track.id)
        #expect(service.lastDeleteRecovery?.originalURL == fileURL)
        #expect(service.lastDeleteRecovery?.trashedURL == trashedFile)
    }

    @Test func deleteWithMissingFileStillRunsDBDelete() async throws {
        let database = try DatabaseManager.inMemory()
        let trackRepo = TrackRepository(database: database)
        let trashDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trashDir) }

        let fileURL = URL(fileURLWithPath: "/nonexistent/path/missing.flac")
        let track = try await insertTrackWithFile(database, fileURL: fileURL)
        let service = makeService(database: database, trackRepository: trackRepo, trashDir: trashDir)

        try await service.delete(track: track)

        #expect(service.lastDeleteRecovery == nil)
        let fetched = try await trackRepo.fetchTrack(id: track.id!)
        #expect(fetched == nil)
    }
}
