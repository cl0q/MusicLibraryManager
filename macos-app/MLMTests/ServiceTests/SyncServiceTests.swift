import Testing
import Foundation
import GRDB
@testable import MLM

@Suite("SyncServiceTests")
@MainActor
struct SyncServiceTests {

    /// Correct init chain — all required params:
    /// TranscodeCache.init(cacheDir: URL)
    /// SyncService.init(trackRepository:syncRepository:configRepository:transcodeCache:)
    private func makeService() throws -> (DatabaseQueue, SyncService) {
        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("svctest_\(UUID().uuidString)")
        let cache = TranscodeCache(cacheDir: cacheDir)
        let service = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )
        return (db, service)
    }

    @Test func cancellationFlagResetsOnNewRun() async throws {
        let (db, service) = try makeService()
        service.cancelSync()
        #expect(service.cancellationRequested == true)

        // Insert a profile with generate_m3u8=0 so generatePlaylists is not called
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files)
                VALUES ('T', '/tmp', '', 0, 'keep_originals', 1, 0)
            """)
        }
        let profile = try await db.read { db in try SyncProfile.fetchOne(db)! }
        // executeSync on a profile with no content: preview will have empty filesToAdd/filesToRemove
        _ = try? await service.executeSync(profileId: profile.id!)
        #expect(service.cancellationRequested == false)
    }

    @Test func cancelMidRunDoesNotCrash() async throws {
        let (db, service) = try makeService()
        service.cancelSync()
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files)
                VALUES ('T', '/tmp', '', 0, 'keep_originals', 1, 0)
            """)
        }
        let profile = try await db.read { db in try SyncProfile.fetchOne(db)! }
        let result = try await service.executeSync(profileId: profile.id!)
        #expect(result.syncedCount == 0)
    }

    @Test func m3u8GateOffSkipsGenerationOnNonExistentPath() async throws {
        let (db, service) = try makeService()
        // Profile with generate_m3u8=0 and nonexistent outputFolder
        // generatePlaylists would fail if called; the gate prevents the call
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files)
                VALUES ('T', '/nonexistent/path', '', 0, 'keep_originals', 1, 0)
            """)
        }
        let profile = try await db.read { db in try SyncProfile.fetchOne(db)! }
        // Should NOT throw because generatePlaylists is skipped
        let result = try await service.executeSync(profileId: profile.id!)
        #expect(result.syncedCount == 0)
    }

    @Test func transcodeModeEnumValuesCorrect() {
        var profile = SyncProfile(name: "T", outputFolder: "/tmp", playlistPathPrefix: "")
        profile.transcodeMode = "keep_originals"
        #expect(profile.transcodeModeEnum == .keepOriginals)

        profile.transcodeMode = "aac_248"
        #expect(profile.transcodeModeEnum == .aac248)

        profile.transcodeMode = "aac_320"
        #expect(profile.transcodeModeEnum == .aac320)
    }

    @Test func processedAndTotalInitializeToZeroAfterEmptySync() async throws {
        let (db, service) = try makeService()
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files)
                VALUES ('T', '/tmp', '', 0, 'keep_originals', 1, 0)
            """)
        }
        let profile = try await db.read { db in try SyncProfile.fetchOne(db)! }
        _ = try? await service.executeSync(profileId: profile.id!)
        #expect(service.processed == 0)
        #expect(service.total == 0)
    }
}
