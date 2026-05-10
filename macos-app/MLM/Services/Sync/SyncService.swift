import Foundation

/// Profile-based device sync service.
///
/// Mirrors the Rust `SyncService`. Resolves profile content (manual tracks +
/// playlists + rules), creates preview diffs, executes file sync with
/// ReplayGain tagging, and generates M3U8 playlists.
@Observable
final class SyncService {

    // MARK: - Types

    struct SyncPreview {
        var filesToAdd: [FilePreview] = []
        var filesToRemove: [FilePreview] = []
        var totalNewSize: Int64 = 0
        var totalRemoveSize: Int64 = 0
        var deviceAvailableSpace: Int64 = 0
        var hasSufficientSpace: Bool = true
    }

    struct FilePreview: Identifiable {
        let id: Int64
        let trackId: Int64
        let title: String
        let artist: String
        let album: String
        let size: Int64
        let destinationPath: String
    }

    struct SyncResult {
        var syncedCount: Int = 0
        var failedCount: Int = 0
        var failedTracks: [(Int64, String)] = []
    }

    // MARK: - State

    private(set) var isRunning = false
    private(set) var progress: Double = 0
    private(set) var currentFile: String = ""

    // MARK: - Dependencies

    private let trackRepository: TrackRepository
    private let syncRepository: SyncRepository
    private let configRepository: ConfigRepository
    private let transcodeCache: TranscodeCache

    /// Space buffer: require 50MB free beyond needed space.
    private static let spaceBuffer: Int64 = 50_000_000

    init(
        trackRepository: TrackRepository,
        syncRepository: SyncRepository,
        configRepository: ConfigRepository,
        transcodeCache: TranscodeCache
    ) {
        self.trackRepository = trackRepository
        self.syncRepository = syncRepository
        self.configRepository = configRepository
        self.transcodeCache = transcodeCache
    }

    // MARK: - Preview

    /// Generate a preview of what would be synced for a profile.
    func previewSync(profileId: Int64) async throws -> SyncPreview {
        guard let profile = try await syncRepository.fetch(id: profileId) else {
            throw SyncError.profileNotFound(profileId)
        }

        let rules = try await syncRepository.fetchProfileRules(profileId: profileId)
        let trackIds = try await trackRepository.fetchTrackIdsForSyncProfile(
            profileId: profileId,
            rules: rules
        )

        let libraryRoot = try await configRepository.getLibraryRoot() ?? ""
        let syncState = try await syncRepository.fetchSyncState(profileId: profileId)
        let syncedTrackIds = Set(syncState.map(\.trackId))

        var preview = SyncPreview()

        // Files to add (in profile but not yet synced)
        let newTrackIds = trackIds.subtracting(syncedTrackIds)
        for trackId in newTrackIds {
            if let track = try await trackRepository.fetchTrack(id: trackId) {
                let destPath = TranscodeCache.buildProfilePath(
                    track: track,
                    libraryRoot: libraryRoot,
                    profileOutputFolder: profile.outputFolder
                )
                let size = estimateFileSize(track: track)

                preview.filesToAdd.append(FilePreview(
                    id: trackId,
                    trackId: trackId,
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    size: size,
                    destinationPath: destPath.path
                ))
                preview.totalNewSize += size
            }
        }

        // Files to remove (synced but no longer in profile)
        let removeTrackIds = syncedTrackIds.subtracting(trackIds)
        for trackId in removeTrackIds {
            if let track = try await trackRepository.fetchTrack(id: trackId) {
                preview.filesToRemove.append(FilePreview(
                    id: trackId,
                    trackId: trackId,
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    size: 0,
                    destinationPath: ""
                ))
            }
        }

        // Space check
        let outputURL = URL(fileURLWithPath: profile.outputFolder)
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: outputURL.path) {
            let available = (attrs[.systemFreeSize] as? Int64) ?? 0
            preview.deviceAvailableSpace = available
            preview.hasSufficientSpace = available >= preview.totalNewSize + Self.spaceBuffer
        }

        return preview
    }

    // MARK: - Execute

    /// Execute sync for a profile.
    func executeSync(profileId: Int64) async throws -> SyncResult {
        guard let profile = try await syncRepository.fetch(id: profileId) else {
            throw SyncError.profileNotFound(profileId)
        }

        let preview = try await previewSync(profileId: profileId)
        guard preview.hasSufficientSpace else {
            throw SyncError.insufficientSpace(
                needed: preview.totalNewSize,
                available: preview.deviceAvailableSpace
            )
        }

        isRunning = true
        defer { isRunning = false }

        var result = SyncResult()
        let total = preview.filesToAdd.count + preview.filesToRemove.count
        var processed = 0

        // 1. Remove stale files
        for file in preview.filesToRemove {
            // Clean up sync_state entry
            try? await syncRepository.removeSyncState(
                profileId: profileId,
                trackId: file.trackId
            )
            processed += 1
            progress = Double(processed) / Double(max(total, 1))
        }

        // 2. Sync new files
        let libraryRoot = try await configRepository.getLibraryRoot() ?? ""
        for file in preview.filesToAdd {
            currentFile = "\(file.artist) - \(file.title)"
            progress = Double(processed) / Double(max(total, 1))

            do {
                // Ensure cached AAC exists
                if let track = try await trackRepository.fetchTrack(id: file.trackId) {
                    if let cachedURL = try await transcodeCache.ensureCached(track: track) {
                        let destURL = TranscodeCache.buildProfilePath(
                            track: track,
                            libraryRoot: libraryRoot,
                            profileOutputFolder: profile.outputFolder
                        )

                        try transcodeCache.linkToProfile(
                            trackId: file.trackId,
                            destinationPath: destURL
                        )

                        // Update sync state
                        let checksum = try TranscodeCache.sha256(of: cachedURL)
                        let size = try FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int ?? 0

                        try await syncRepository.updateSyncState(
                            profileId: profileId,
                            trackId: file.trackId,
                            checksum: checksum,
                            size: size
                        )

                        result.syncedCount += 1
                    } else {
                        result.failedCount += 1
                        result.failedTracks.append((file.trackId, "Transcode failed"))
                    }
                }
            } catch {
                result.failedCount += 1
                result.failedTracks.append((file.trackId, error.localizedDescription))
            }

            processed += 1
        }

        // 3. Generate M3U8 playlists
        try await generatePlaylists(profileId: profileId, profile: profile, libraryRoot: libraryRoot)

        currentFile = ""
        progress = 1.0
        return result
    }

    // MARK: - M3U8 Generation

    /// Generate M3U8 playlist files for each playlist in the profile.
    private func generatePlaylists(profileId: Int64, profile: SyncProfile, libraryRoot: String) async throws {
        let playlists = try await syncRepository.fetchProfilePlaylists(profileId: profileId)
        let profileDir = URL(fileURLWithPath: profile.outputFolder)

        for playlist in playlists {
            let playlistRepo = PlaylistRepository(database: syncRepository.databasePool)
            let tracks = try await playlistRepo.fetchTracks(playlistId: playlist.id!)

            var m3u = "#EXTM3U\n"
            for track in tracks {
                let duration = track.duration ?? 0
                let destPath = TranscodeCache.buildProfilePath(
                    track: track,
                    libraryRoot: libraryRoot,
                    profileOutputFolder: profile.outputFolder
                )
                // Make path relative to profile root
                let relativePath = destPath.path
                    .replacingOccurrences(of: profileDir.path + "/", with: "")
                let prefix = profile.playlistPathPrefix
                let fullPath = prefix.isEmpty ? relativePath : "\(prefix)/\(relativePath)"

                m3u += "#EXTINF:\(duration),\(track.artist) - \(track.title)\n"
                m3u += "\(fullPath)\n"
            }

            let playlistName = PathSanitizer.sanitizeComponent(playlist.name) + ".m3u8"
            let playlistPath = profileDir.appendingPathComponent(playlistName)
            try m3u.write(to: playlistPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Helpers

    private func estimateFileSize(track: Track) -> Int64 {
        // Estimate: 248kbps * duration = bytes
        let duration = Double(track.duration ?? 240)  // default 4 min
        return Int64(248_000 / 8 * duration)
    }
}
