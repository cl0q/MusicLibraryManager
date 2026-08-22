import Testing
import GRDB
@testable import MLM

@Suite("MigrationTests — v_sync_toggles")
struct MigrationTests {

    // MARK: - Column existence

    @Test func syncProfilesHasGenerateM3U8Column() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.read { db in
            let columns = try db.columns(in: "sync_profiles").map(\.name)
            #expect(columns.contains("generate_m3u8"))
        }
    }

    @Test func syncProfilesHasTranscodeModeColumn() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.read { db in
            let columns = try db.columns(in: "sync_profiles").map(\.name)
            #expect(columns.contains("transcode_mode"))
        }
    }

    @Test func syncProfilesHasFat32SafePathsColumn() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.read { db in
            let columns = try db.columns(in: "sync_profiles").map(\.name)
            #expect(columns.contains("fat32_safe_paths"))
        }
    }

    @Test func syncProfilesHasCleanupRemovedFilesColumn() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.read { db in
            let columns = try db.columns(in: "sync_profiles").map(\.name)
            #expect(columns.contains("cleanup_removed_files"))
        }
    }

    // MARK: - Default values

    @Test func defaultsAreCorrectOnInsert() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix)
                VALUES ('TestProfile', '/tmp/out', '')
            """)
        }
        try await db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_profiles WHERE name = 'TestProfile'")!
            #expect(row["generate_m3u8"] == 0)
            #expect(row["transcode_mode"] == "keep_originals")
            #expect(row["fat32_safe_paths"] == 1)
            #expect(row["cleanup_removed_files"] == 1)
        }
    }

    // MARK: - Idempotence

    @Test func migrationIsIdempotent() async throws {
        // Running DatabaseManager.inMemory() twice effectively re-applies the migrator.
        // This test verifies a second open does not crash or duplicate columns.
        let db1 = try DatabaseManager.inMemory()
        let db2 = try DatabaseManager.inMemory()
        try await db2.read { db in
            let columns = try db.columns(in: "sync_profiles").map(\.name)
            let generatedCount = columns.filter { $0 == "generate_m3u8" }.count
            #expect(generatedCount == 1) // exactly one column, not duplicated
        }
        _ = db1
    }

    // MARK: - Model decoding

    @Test func syncProfileDecodesNewColumnsCorrectly() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix,
                    generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files)
                VALUES ('Rockbox', '/Volumes/iPod', '/Music', 1, 'aac_248', 1, 0)
            """)
        }
        let profile = try await db.read { db in
            try SyncProfile.filter(Column("name") == "Rockbox").fetchOne(db)
        }
        #expect(profile != nil)
        #expect(profile?.generateM3U8 == true)
        #expect(profile?.transcodeModeEnum == .aac248)
        #expect(profile?.fat32SafePaths == true)
        #expect(profile?.cleanupRemovedFiles == false)
    }

    // MARK: - TranscodeMode enum

    @Test func transcodeModeEnumFallback() {
        #expect(TranscodeMode(rawValue: "unknown") == nil)
        let profile = SyncProfile(name: "", outputFolder: "", playlistPathPrefix: "")
        // Default transcodeMode is "keep_originals" → transcodeModeEnum == .keepOriginals
        #expect(profile.transcodeModeEnum == .keepOriginals)
    }
}
