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

    @Test func isStaleOrganizedPathDetectsStagingInDifferentPositions() {
        #expect(TranscodeCache.isStaleOrganizedPath(".mlm_staging/transcoded/track.m4a") == true)
        #expect(TranscodeCache.isStaleOrganizedPath("/.mlm_staging/transcoded/track.m4a") == true)
        #expect(TranscodeCache.isStaleOrganizedPath("/Volumes/Library/.mlm_staging/transcoded/track.m4a") == true)
        #expect(TranscodeCache.isStaleOrganizedPath(".ln/track.m4a") == true)
        #expect(TranscodeCache.isStaleOrganizedPath("/Volumes/Library/.ln/track.m4a") == true)
        #expect(TranscodeCache.isStaleOrganizedPath("00_Artists/track.m4a") == false)
    }

    @Test func buildProfilePathRejectsStalePathsAndRoutesSoundCloud() {
        let scTrack = Track(
            id: 1,
            artist: ".",
            albumArtist: ".",
            album: ".",
            title: "My SoundCloud Track",
            genre: nil,
            year: nil,
            bitrate: nil,
            duration: 180,
            format: "m4a",
            originalPath: "https://soundcloud.com/user/track",
            organizedPath: "/Volumes/Library/.mlm_staging/transcoded/My SoundCloud Track.m4a",
            isDuplicate: 0,
            dateAdded: nil,
            variantOf: nil,
            downloadStatus: nil,
            lufsI: nil,
            lufsRange: nil,
            truePeak: nil,
            energyBucket: nil,
            danceability: nil,
            albumId: nil,
            searchText: nil
        )

        let profilePath = TranscodeCache.buildProfilePath(
            track: scTrack,
            libraryRoot: "/Volumes/Library",
            profileOutputFolder: "/Volumes/IPOD/Music/MLM"
        )

        // Stale organizedPath should be rejected, falls back to soundcloud check
        // SoundCloud should be mapped to 03_Club/SoundCloud/title.m4a
        #expect(profilePath.path == "/Volumes/IPOD/Music/MLM/03_Club/SoundCloud/My SoundCloud Track.m4a")
    }

    @Test func buildProfilePathPreservesValidLibraryPaths() {
        let validTrack = Track(
            id: 2,
            artist: "Artist A",
            albumArtist: "Artist A",
            album: "Album 1",
            title: "Track 1",
            genre: nil,
            year: nil,
            bitrate: nil,
            duration: 180,
            format: "m4a",
            originalPath: "/Volumes/Library/00_Artists/Artist A/Album 1/Track 1.m4a",
            organizedPath: "00_Artists/Artist A/Album 1/Track 1.m4a",
            isDuplicate: 0,
            dateAdded: nil,
            variantOf: nil,
            downloadStatus: nil,
            lufsI: nil,
            lufsRange: nil,
            truePeak: nil,
            energyBucket: nil,
            danceability: nil,
            albumId: nil,
            searchText: nil
        )

        let profilePath = TranscodeCache.buildProfilePath(
            track: validTrack,
            libraryRoot: "/Volumes/Library",
            profileOutputFolder: "/Volumes/IPOD/Music/MLM"
        )

        #expect(profilePath.path == "/Volumes/IPOD/Music/MLM/00_Artists/Artist A/Album 1/Track 1.m4a")
    }

    @Test func buildProfilePathSanitizesEmojiAndSpecialCharacters() {
        let dirtyTrack = Track(
            id: 3,
            artist: "Artist B",
            albumArtist: "Artist B",
            album: "Album 2?",
            title: "Track 2?",
            genre: nil,
            year: nil,
            bitrate: nil,
            duration: 180,
            format: "mp3",
            originalPath: "/Volumes/Library/05_Playlists/What is this melody?/Track 2.mp3",
            organizedPath: "05_Playlists/What is this melody?/Track 2.mp3",
            isDuplicate: 0,
            dateAdded: nil,
            variantOf: nil,
            downloadStatus: nil,
            lufsI: nil,
            lufsRange: nil,
            truePeak: nil,
            energyBucket: nil,
            danceability: nil,
            albumId: nil,
            searchText: nil
        )

        let profilePath = TranscodeCache.buildProfilePath(
            track: dirtyTrack,
            libraryRoot: "/Volumes/Library",
            profileOutputFolder: "/Volumes/IPOD/Music/MLM"
        )

        #expect(profilePath.path == "/Volumes/IPOD/Music/MLM/05_Playlists/What is this melody_/Track 2.m4a")
    }

    @Test func buildProfilePathPreservesOriginalExtensionInKeepOriginals() {
        let mp3Track = Track(
            id: 4,
            artist: "Artist C",
            albumArtist: "Artist C",
            album: "Album 3",
            title: "Track 3",
            genre: nil,
            year: nil,
            bitrate: nil,
            duration: 180,
            format: "mp3",
            originalPath: "/Volumes/Library/00_Artists/Artist C/Album 3/Track 3.mp3",
            organizedPath: "00_Artists/Artist C/Album 3/Track 3.mp3",
            isDuplicate: 0,
            dateAdded: nil,
            variantOf: nil,
            downloadStatus: nil,
            lufsI: nil,
            lufsRange: nil,
            truePeak: nil,
            energyBucket: nil,
            danceability: nil,
            albumId: nil,
            searchText: nil
        )

        let profilePath = TranscodeCache.buildProfilePath(
            track: mp3Track,
            libraryRoot: "/Volumes/Library",
            profileOutputFolder: "/Volumes/IPOD/Music/MLM",
            transcodeMode: .keepOriginals
        )

        #expect(profilePath.path == "/Volumes/IPOD/Music/MLM/00_Artists/Artist C/Album 3/Track 3.mp3")
    }

    @Test func testPreviewSyncPopulatesCorrectDestinationPathForFilesToRemove() async throws {
        let (db, service) = try makeService()
        
        // 1. Configure a sync profile
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profiles
                    (id, name, output_folder, playlist_path_prefix, generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files, playlist_format)
                VALUES (42, 'Test Profile', '/Volumes/IPOD/Music/MLM', '', 1, 'keep_originals', 1, 1, 'doppi')
            """)
            
            // 2. Insert a track
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, organized_path, is_duplicate)
                VALUES (101, 'Artist D', 'Artist D', 'Album 4', 'Track 4', 'mp3', '/Volumes/Library/00_Artists/Artist D/Album 4/Track 4.mp3', '00_Artists/Artist D/Album 4/Track 4.mp3', 0)
            """)
            
            // 3. Mark the track as synced in sync_state (meaning it was in a previous sync but now rules changed)
            try db.execute(sql: """
                INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (42, 101, 'abc', 1000, '2026-05-23 12:00:00')
            """)
        }
        
        // Let's call previewSync. Since no rules/playlists are linked to profile 42,
        // track 101 is NOT in the profile but is in sync_state, so it must be added to filesToRemove!
        let preview = try await service.previewSync(profileId: 42)
        
        #expect(preview.filesToRemove.count == 1)
        if preview.filesToRemove.count == 1 {
            let fileToRemove = preview.filesToRemove[0]
            #expect(fileToRemove.trackId == 101)
            #expect(fileToRemove.destinationPath == "/Volumes/IPOD/Music/MLM/00_Artists/Artist D/Album 4/Track 4.mp3")
        }
    }

    @Test func testSyncProfilePlaylistFormatExtensions() {
        var rockboxProfile = SyncProfile(name: "Rockbox", outputFolder: "/tmp")
        rockboxProfile.playlistFormat = "rockbox"
        #expect(rockboxProfile.playlistFormatEnum == .rockbox)

        var doppiProfile = SyncProfile(name: "Doppi", outputFolder: "/tmp")
        doppiProfile.playlistFormat = "doppi"
        #expect(doppiProfile.playlistFormatEnum == .doppi)
    }
}


