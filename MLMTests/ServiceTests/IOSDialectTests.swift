import Testing
import Foundation
import GRDB
@testable import MLM

@Suite("IOSDialectTests")
@MainActor
struct IOSDialectTests {

    private func makeService() throws -> (DatabaseQueue, SyncService) {
        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosdialect_\(UUID().uuidString)")
        let cache = TranscodeCache(cacheDir: cacheDir)
        let service = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )
        return (db, service)
    }

    // MARK: - Dialect Output

    @Test func iosDialectProducesCorrectM3U8Content() async throws {
        let (db, service) = try makeService()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-dialect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        // Create a fake track file in the output folder at the path buildProfilePath will compute
        // iOS layout: <output>/Music/<Artist>/<Album>/<Title>.<ext>
        let trackDir = output.appendingPathComponent("Music/Test Artist/Test Album")
        try FileManager.default.createDirectory(at: trackDir, withIntermediateDirectories: true)
        let trackFile = trackDir.appendingPathComponent("Test Title.m4a")
        try Data(repeating: 0, count: 100).write(to: trackFile)

        // Seed DB: profile with .ios format, playlist, track with known UUID
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (id, name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files, playlist_format)
                VALUES (100, 'iOS Test', ?, '', 1, 'keep_originals', 1, 0, 'ios')
                """, arguments: [output.path])
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, duration, original_path, is_duplicate, mlm_uuid)
                VALUES (1001, 'Test Artist', 'Test Album Artist', 'Test Album', 'Test Title', 'm4a', 240, ?, 0, 'TRACK-UUID-001')
                """, arguments: [trackFile.path])
            try db.execute(sql: """
                INSERT INTO playlists (id, name, category, mlm_uuid) VALUES (1010, 'My Playlist', 'regular', 'PLAYLIST-UUID-001')
                """)
            try db.execute(sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (1010, 1001, 'a0')
                """)
            try db.execute(sql: """
                INSERT INTO sync_profile_playlists (profile_id, playlist_id) VALUES (100, 1010)
                """)
            // Mark track as synced so executeSync doesn't try to re-sync
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (100, 1001, 'abc', 100, datetime('now'))
                """)
        }

        _ = try await service.executeSync(profileId: 100)

        // Read the generated playlist — iOS writes to <root>/Playlists/
        let playlistFile = output.appendingPathComponent("Playlists/My Playlist.m3u8")
        #expect(FileManager.default.fileExists(atPath: playlistFile.path))

        let content = try String(contentsOf: playlistFile, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")

        // Verify header
        #expect(lines[0] == "#EXTM3U")
        #expect(lines[1] == "#EXTMLM-PLAYLIST:PLAYLIST-UUID-001")

        // Verify track entry — m3u8 paths include Music/ prefix (relative to <root>)
        #expect(lines[2].hasPrefix("#EXTINF:240,"))
        #expect(lines[2].contains("Test Artist - Test Title"))
        #expect(lines[3] == "#EXTMLM:TRACK-UUID-001")
        #expect(lines[4] == "Music/Test Artist/Test Album/Test Title.m4a")
    }

    // MARK: - UUID Lazy Generation

    @Test func iosDialectGeneratesStableUuids() async throws {
        let (db, service) = try makeService()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-uuid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        // Create a fake track file at the path buildProfilePath computes: <output>/Music/Artist/Album/Song.m4a
        let trackDir = output.appendingPathComponent("Music/Artist/Album")
        try FileManager.default.createDirectory(at: trackDir, withIntermediateDirectories: true)
        let trackFile = trackDir.appendingPathComponent("Song.m4a")
        try Data(repeating: 0, count: 100).write(to: trackFile)

        // Seed DB: track and playlist WITHOUT uuids
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (id, name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files, playlist_format)
                VALUES (200, 'UUID Test', ?, '', 1, 'keep_originals', 1, 0, 'ios')
                """, arguments: [output.path])
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, duration, original_path, is_duplicate)
                VALUES (2001, 'Artist', 'Artist', 'Album', 'Song', 'm4a', 180, ?, 0)
                """, arguments: [trackFile.path])
            try db.execute(sql: """
                INSERT INTO playlists (id, name, category) VALUES (2010, 'Test PL', 'regular')
                """)
            try db.execute(sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (2010, 2001, 'a0')
                """)
            try db.execute(sql: """
                INSERT INTO sync_profile_playlists (profile_id, playlist_id) VALUES (200, 2010)
                """)
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (200, 2001, 'abc', 100, datetime('now'))
                """)
        }

        // First sync
        _ = try await service.executeSync(profileId: 200)

        // Read UUIDs from DB
        let firstUUIDs = try await db.read { db in
            let track = try Track.fetchOne(db, key: 2001)!
            let playlist = try Playlist.fetchOne(db, key: 2010)!
            return (track: track.mlmUuid, playlist: playlist.mlmUuid)
        }

        #expect(firstUUIDs.track != nil)
        #expect(firstUUIDs.playlist != nil)

        // Second sync - UUIDs should be identical
        _ = try await service.executeSync(profileId: 200)

        let secondUUIDs = try await db.read { db in
            let track = try Track.fetchOne(db, key: 2001)!
            let playlist = try Playlist.fetchOne(db, key: 2010)!
            return (track: track.mlmUuid, playlist: playlist.mlmUuid)
        }

        #expect(firstUUIDs.track == secondUUIDs.track)
        #expect(firstUUIDs.playlist == secondUUIDs.playlist)
    }

    // MARK: - Missing File Gating

    @Test func iosDialectOmitsTracksWithoutPhysicalFiles() async throws {
        let (db, service) = try makeService()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        // Create only ONE track file (track 3002) at the path buildProfilePath computes
        let trackDir = output.appendingPathComponent("Music/Artist/Album")
        try FileManager.default.createDirectory(at: trackDir, withIntermediateDirectories: true)
        let existingFile = trackDir.appendingPathComponent("Existing.m4a")
        try Data(repeating: 0, count: 100).write(to: existingFile)

        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (id, name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files, playlist_format)
                VALUES (300, 'Missing Test', ?, '', 1, 'keep_originals', 1, 0, 'ios')
                """, arguments: [output.path])
            // Track 3001: file does NOT exist
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, duration, original_path, is_duplicate, mlm_uuid)
                VALUES (3001, 'Artist', 'Artist', 'Album', 'Missing', 'm4a', 120, '/nonexistent.m4a', 0, 'MISSING-UUID')
                """)
            // Track 3002: file EXISTS
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, duration, original_path, is_duplicate, mlm_uuid)
                VALUES (3002, 'Artist', 'Artist', 'Album', 'Existing', 'm4a', 200, ?, 0, 'EXISTING-UUID')
                """, arguments: [existingFile.path])
            try db.execute(sql: """
                INSERT INTO playlists (id, name, category, mlm_uuid) VALUES (3010, 'PL', 'regular', 'PL-UUID')
                """)
            try db.execute(sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (3010, 3001, 'a0')
                """)
            try db.execute(sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (3010, 3002, 'a1')
                """)
            try db.execute(sql: """
                INSERT INTO sync_profile_playlists (profile_id, playlist_id) VALUES (300, 3010)
                """)
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (300, 3001, 'abc', 100, datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (300, 3002, 'def', 100, datetime('now'))
                """)
        }

        _ = try await service.executeSync(profileId: 300)

        let playlistFile = output.appendingPathComponent("Playlists/PL.m3u8")
        let content = try String(contentsOf: playlistFile, encoding: .utf8)

        // Should NOT contain the missing track's UUID
        #expect(!content.contains("MISSING-UUID"))
        // Should contain the existing track's UUID
        #expect(content.contains("EXISTING-UUID"))
    }

    // MARK: - Manifest

    @Test func manifestWritesCorrectJSON() async throws {
        let (db, service) = try makeService()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        // Create a track file at the path buildProfilePath computes: <output>/Music/Test Artist/Test Album/Test Song.m4a
        let trackDir = output.appendingPathComponent("Music/Test Artist/Test Album")
        try FileManager.default.createDirectory(at: trackDir, withIntermediateDirectories: true)
        let trackFile = trackDir.appendingPathComponent("Test Song.m4a")
        try Data(repeating: 0, count: 100).write(to: trackFile)

        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (id, name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files, playlist_format)
                VALUES (400, 'Manifest Test', ?, '', 1, 'keep_originals', 1, 0, 'ios')
                """, arguments: [output.path])
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, duration, original_path, is_duplicate, mlm_uuid, energy_bucket, lufs_i)
                VALUES (4001, 'Test Artist', 'Test Album Artist', 'Test Album', 'Test Song', 'm4a', 300, ?, 0, 'MANIFEST-TRACK-UUID', 2, -14.5)
                """, arguments: [trackFile.path])
            try db.execute(sql: """
                INSERT INTO playlists (id, name, category, mlm_uuid) VALUES (4010, 'Test Playlist', 'regular', 'MANIFEST-PL-UUID')
                """)
            try db.execute(sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (4010, 4001, 'a0')
                """)
            try db.execute(sql: """
                INSERT INTO sync_profile_tracks (profile_id, track_id) VALUES (400, 4001)
                """)
            try db.execute(sql: """
                INSERT INTO sync_profile_playlists (profile_id, playlist_id) VALUES (400, 4010)
                """)
        }

        let profile = try await db.read { db in try SyncProfile.fetchOne(db, key: 400)! }
        try await service.generateManifest(profileId: 400, profile: profile, libraryRoot: "")

        let manifestFile = output.appendingPathComponent("mlm-library.json")
        #expect(FileManager.default.fileExists(atPath: manifestFile.path))

        let data = try Data(contentsOf: manifestFile)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Verify schema fields
        #expect(json["schema"] as? Int == 1)
        #expect(json["profile"] as? String == "Manifest Test")
        #expect(json["generated_at"] != nil)

        // Verify tracks
        let tracks = json["tracks"] as? [[String: Any]] ?? []
        #expect(tracks.count == 1)
        if let track = tracks.first {
            #expect(track["uuid"] as? String == "MANIFEST-TRACK-UUID")
            #expect(track["title"] as? String == "Test Song")
            #expect(track["artist"] as? String == "Test Artist")
            #expect(track["album_artist"] as? String == "Test Album Artist")
            #expect(track["album"] as? String == "Test Album")
            #expect(track["duration"] as? Int == 300)
            #expect(track["path"] as? String == "Test Artist/Test Album/Test Song.m4a")
            #expect(track["energy_bucket"] as? Int == 2)
            #expect(track["lufs_i"] as? Double == -14.5)
        }

        // Verify playlists
        let playlists = json["playlists"] as? [[String: Any]] ?? []
        #expect(playlists.count == 1)
        if let pl = playlists.first {
            #expect(pl["uuid"] as? String == "MANIFEST-PL-UUID")
            #expect(pl["name"] as? String == "Test Playlist")
            #expect(pl["file"] as? String == "Test Playlist.m3u8")
        }
    }

    @Test func manifestOmitsTracksWithoutFiles() async throws {
        let (db, service) = try makeService()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-manifest-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (id, name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files, playlist_format)
                VALUES (500, 'Missing Manifest', ?, '', 1, 'keep_originals', 1, 0, 'ios')
                """, arguments: [output.path])
            // Track with no physical file
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, duration, original_path, is_duplicate, mlm_uuid)
                VALUES (5001, 'Artist', 'Artist', 'Album', 'Missing', 'm4a', 120, '/nonexistent.m4a', 0, 'MISSING-UUID')
                """)
            try db.execute(sql: """
                INSERT INTO sync_profile_tracks (profile_id, track_id) VALUES (500, 5001)
                """)
        }

        let profile = try await db.read { db in try SyncProfile.fetchOne(db, key: 500)! }
        try await service.generateManifest(profileId: 500, profile: profile, libraryRoot: "")

        let manifestFile = output.appendingPathComponent("mlm-library.json")
        let data = try Data(contentsOf: manifestFile)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let tracks = json["tracks"] as? [[String: Any]] ?? []
        #expect(tracks.isEmpty)
    }

    // MARK: - Layout Contract (spec §2/§3)

    /// Manifest `path` values are relative to `<root>/Music/` (no `Music/` prefix),
    /// while m3u8 entry paths are relative to `<root>` (include `Music/` prefix).
    @Test func manifestPathsHaveNoMusicPrefixWhileM3U8EntriesDo() async throws {
        let (db, service) = try makeService()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-layout-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        // Create track file at iOS layout path: <root>/Music/Artist/Album/Song.m4a
        let trackDir = output.appendingPathComponent("Music/Artist/Album")
        try FileManager.default.createDirectory(at: trackDir, withIntermediateDirectories: true)
        let trackFile = trackDir.appendingPathComponent("Song.m4a")
        try Data(repeating: 0, count: 100).write(to: trackFile)

        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (id, name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files, playlist_format)
                VALUES (1, 'Layout', ?, '', 1, 'keep_originals', 1, 0, 'ios')
                """, arguments: [output.path])
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, duration, original_path, is_duplicate, mlm_uuid)
                VALUES (100, 'Artist', 'Artist', 'Album', 'Song', 'm4a', 180, ?, 0, 'LAYOUT-UUID')
                """, arguments: [trackFile.path])
            try db.execute(sql: """
                INSERT INTO playlists (id, name, category, mlm_uuid) VALUES (200, 'Layout PL', 'regular', 'LAYOUT-PL-UUID')
                """)
            try db.execute(sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (200, 100, 'a0')
                """)
            try db.execute(sql: """
                INSERT INTO sync_profile_tracks (profile_id, track_id) VALUES (1, 100)
                """)
            try db.execute(sql: """
                INSERT INTO sync_profile_playlists (profile_id, playlist_id) VALUES (1, 200)
                """)
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (1, 100, 'abc', 100, datetime('now'))
                """)
        }

        _ = try await service.executeSync(profileId: 1)

        // 1. m3u8 entry path includes Music/ prefix (relative to <root>)
        let m3u8File = output.appendingPathComponent("Playlists/Layout PL.m3u8")
        #expect(FileManager.default.fileExists(atPath: m3u8File.path))
        let m3u8Content = try String(contentsOf: m3u8File, encoding: .utf8)
        #expect(m3u8Content.contains("Music/Artist/Album/Song.m4a"))

        // 2. Manifest path has NO Music/ prefix (relative to <root>/Music/)
        let manifestFile = output.appendingPathComponent("mlm-library.json")
        #expect(FileManager.default.fileExists(atPath: manifestFile.path))
        let manifestData = try Data(contentsOf: manifestFile)
        let manifestJSON = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
        let manifestTracks = manifestJSON["tracks"] as? [[String: Any]] ?? []
        #expect(manifestTracks.count == 1)
        let manifestPath = manifestTracks.first?["path"] as? String
        #expect(manifestPath == "Artist/Album/Song.m4a")
        #expect(!(manifestPath?.hasPrefix("Music/") ?? true))
    }

    // MARK: - Regression: Rockbox/Doppi Unchanged

    @Test func rockboxFormatStillWorks() async throws {
        let (db, service) = try makeService()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("rockbox-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let trackDir = output.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: trackDir, withIntermediateDirectories: true)
        let trackFile = trackDir.appendingPathComponent("Song.mp3")
        try Data(repeating: 0, count: 100).write(to: trackFile)

        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (id, name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files, playlist_format)
                VALUES (600, 'Rockbox', ?, '', 1, 'keep_originals', 1, 0, 'rockbox')
                """, arguments: [output.path])
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, duration, original_path, is_duplicate)
                VALUES (6001, 'Artist', 'Artist', 'Album', 'Song', 'mp3', 180, ?, 0)
                """, arguments: [trackFile.path])
            try db.execute(sql: """
                INSERT INTO playlists (id, name, category) VALUES (6010, 'Rock PL', 'regular')
                """)
            try db.execute(sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (6010, 6001, 'a0')
                """)
            try db.execute(sql: """
                INSERT INTO sync_profile_playlists (profile_id, playlist_id) VALUES (600, 6010)
                """)
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (600, 6001, 'abc', 100, datetime('now'))
                """)
        }

        _ = try await service.executeSync(profileId: 600)

        let playlistFile = output.appendingPathComponent("Rock PL.m3u8")
        #expect(FileManager.default.fileExists(atPath: playlistFile.path))

        let content = try String(contentsOf: playlistFile, encoding: .utf8)
        // Rockbox should NOT have EXTMLM headers
        #expect(!content.contains("#EXTMLM"))
        // Should have standard EXTINF
        #expect(content.contains("#EXTINF:180,"))
    }

    @Test func doppiFormatStillWorks() async throws {
        let (db, service) = try makeService()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("doppi-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let trackDir = output.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: trackDir, withIntermediateDirectories: true)
        let trackFile = trackDir.appendingPathComponent("Song.mp3")
        try Data(repeating: 0, count: 100).write(to: trackFile)

        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (id, name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files, playlist_format)
                VALUES (700, 'Doppi', ?, '', 1, 'keep_originals', 1, 0, 'doppi')
                """, arguments: [output.path])
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, duration, original_path, is_duplicate)
                VALUES (7001, 'Artist', 'Artist', 'Album', 'Song', 'mp3', 180, ?, 0)
                """, arguments: [trackFile.path])
            try db.execute(sql: """
                INSERT INTO playlists (id, name, category) VALUES (7010, 'Doppi PL', 'regular')
                """)
            try db.execute(sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (7010, 7001, 'a0')
                """)
            try db.execute(sql: """
                INSERT INTO sync_profile_playlists (profile_id, playlist_id) VALUES (700, 7010)
                """)
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (700, 7001, 'abc', 100, datetime('now'))
                """)
        }

        _ = try await service.executeSync(profileId: 700)

        // Doppi uses .m3u extension
        let playlistFile = output.appendingPathComponent("Doppi PL.m3u")
        #expect(FileManager.default.fileExists(atPath: playlistFile.path))

        let content = try String(contentsOf: playlistFile, encoding: .utf8)
        // Doppi should NOT have EXTMLM headers
        #expect(!content.contains("#EXTMLM"))
        // Doppi paths start with /
        #expect(content.contains("/Artist/Album/Song.mp3"))
    }

    @Test func playlistFormatEnumIncludesIOS() {
        var iosProfile = SyncProfile(name: "iOS", outputFolder: "/tmp")
        iosProfile.playlistFormat = "ios"
        #expect(iosProfile.playlistFormatEnum == .ios)
    }
}
