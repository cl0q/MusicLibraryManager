import Foundation
import AVFoundation

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
        var skippedCount: Int = 0
        var failedTracks: [(Int64, String)] = []
    }

    // MARK: - State

    private(set) var isRunning = false
    private(set) var progress: Double = 0
    private(set) var currentFile: String = ""

    // MARK: - Cancellation + Progress Tracking (D-14)

    private(set) var cancellationRequested: Bool = false
    private(set) var processed: Int = 0
    private(set) var total: Int = 0

    func cancelSync() {
        cancellationRequested = true
    }

    // MARK: - Dependencies

    private let trackRepository: TrackRepository
    private let syncRepository: SyncRepository
    private let configRepository: ConfigRepository
    private let transcodeCache: TranscodeCache

    /// Optional bridge to the global Operations panel.
    /// When set, executeSync registers itself as an ActivityViewModel.Operation
    /// so the Operations tab can render a live row.
    var activityViewModel: ActivityViewModel?

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

        // Files to add (in profile but not yet synced, OR physical file is missing/stale/corrupted on the destination drive)
        for trackId in trackIds {
            if let track = try await trackRepository.fetchTrack(id: trackId) {
                let destPath = TranscodeCache.buildProfilePath(
                    track: track,
                    libraryRoot: libraryRoot,
                    profileOutputFolder: profile.outputFolder,
                    transcodeMode: profile.transcodeModeEnum
                )
                
                var needsSync = false
                if !syncedTrackIds.contains(trackId) {
                    needsSync = true
                } else if !FileManager.default.fileExists(atPath: destPath.path) {
                    // Expected physical file doesn't exist on destination (e.g. extension changed or manually deleted)
                    needsSync = true
                } else if profile.transcodeModeEnum != .keepOriginals {
                    // Sync expects a transcoded AAC file, verify that the physical file is actually a valid AAC container (not a renamed MP3/FLAC)
                    if await transcodeCache.verifyCacheCodec(destPath) == false {
                        needsSync = true
                    }
                }
                
                if needsSync {
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
        }

        // Files to remove (synced but no longer in profile)
        let removeTrackIds = syncedTrackIds.subtracting(trackIds)
        for trackId in removeTrackIds {
            if let track = try await trackRepository.fetchTrack(id: trackId) {
                let destPath = TranscodeCache.buildProfilePath(
                    track: track,
                    libraryRoot: libraryRoot,
                    profileOutputFolder: profile.outputFolder,
                    transcodeMode: profile.transcodeModeEnum
                )
                preview.filesToRemove.append(FilePreview(
                    id: trackId,
                    trackId: trackId,
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    size: 0,
                    destinationPath: destPath.path
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

        // Reset cancellation flag + progress tracking at start (D-14)
        cancellationRequested = false
        total = preview.filesToAdd.count + preview.filesToRemove.count
        processed = 0

        isRunning = true
        defer { isRunning = false }

        var result = SyncResult()

        AppLogger.shared.info(
            "Sync starting: profile=\(profile.name) (id=\(profileId)) mode=\(profile.transcodeMode) toAdd=\(preview.filesToAdd.count) toRemove=\(preview.filesToRemove.count) output=\(profile.outputFolder)",
            source: "Sync"
        )

        // Register with global Operations panel (Task 1 — Sync-Progress moved
        // from SyncView into Operations-Tab).
        let operationId: UUID? = await MainActor.run {
            activityViewModel?.startOperation(
                type: .sync,
                title: "Sync: \(profile.name)",
                detail: "0 / \(total)"
            )
        }

        // 1. Remove stale files (cleanup-deletion branch — D-04 / SYNC-v2-05)
        for file in preview.filesToRemove {
            if profile.cleanupRemovedFiles {
                let url = URL(fileURLWithPath: file.destinationPath)
                // Security guard: only delete within profile.outputFolder (T-38-02)
                guard file.destinationPath.hasPrefix(profile.outputFolder) else {
                    AppLogger.shared.log(
                        "Cleanup skipped: path outside outputFolder: \(file.destinationPath)",
                        level: .warning,
                        source: "sync"
                    )
                    continue
                }
                // Resolve symlinks to prevent symlink-following attacks (T-38-03)
                let canonicalURL = url.resolvingSymlinksInPath()
                guard canonicalURL.path.hasPrefix(profile.outputFolder) else { continue }

                if FileManager.default.fileExists(atPath: canonicalURL.path) {
                    var trashed: NSURL? = nil
                    do {
                        try FileManager.default.trashItem(at: canonicalURL, resultingItemURL: &trashed)
                    } catch {
                        // FAT32/exFAT destinations don't support Trash — fall back to direct remove
                        try? FileManager.default.removeItem(at: canonicalURL)
                    }
                }
            }
            try? await syncRepository.removeSyncState(
                profileId: profileId,
                trackId: file.trackId
            )
            processed += 1
            progress = Double(processed) / Double(max(total, 1))
            if let operationId {
                await MainActor.run {
                    activityViewModel?.updateProgress(
                        id: operationId,
                        progress: progress,
                        detail: "\(processed) / \(total) — Entfernt: \(file.artist) - \(file.title)"
                    )
                }
            }
            if cancellationRequested { break }
        }

        // 2. Sync new files
        let libraryRoot = try await configRepository.getLibraryRoot() ?? ""
        for file in preview.filesToAdd {
            currentFile = "\(file.artist) - \(file.title)"
            progress = Double(processed) / Double(max(total, 1))
            if let operationId {
                await MainActor.run {
                    activityViewModel?.updateProgress(
                        id: operationId,
                        progress: progress,
                        detail: "\(processed) / \(total) — \(file.artist) - \(file.title)"
                    )
                }
            }

            do {
                if let track = try await trackRepository.fetchTrack(id: file.trackId) {
                    // Determine if the track is actually syncable (has a local file/source)
                    var isSyncable = false
                    var candidatePaths: [String] = []
                    if let op = track.organizedPath { candidatePaths.append(op) }
                    if track.isLocal { candidatePaths.append(track.originalPath) }
                    
                    for candidate in candidatePaths {
                        if TranscodeCache.resolveSourceURL(sourcePath: candidate, libraryRoot: libraryRoot) != nil {
                            isSyncable = true
                            break
                        }
                    }
                    
                    if !isSyncable {
                        result.skippedCount += 1
                        AppLogger.shared.warn(
                            "Sync skipped (no local file): track \(file.trackId) \(file.artist) - \(file.title) is stream-only or missing on-disk (tried \(candidatePaths))",
                            source: "Sync"
                        )
                        processed += 1
                        if cancellationRequested { break }
                        continue
                    }

                    // Transcode-mode branching (SYNC-v2-19)
                    let cachedURL: URL?
                    switch profile.transcodeModeEnum {
                    case .keepOriginals:
                        // Bypass TranscodeCache — link original file directly (no transcode)
                        if let organizedPath = track.organizedPath,
                           let sourceURL = TranscodeCache.resolveSourceURL(sourcePath: organizedPath, libraryRoot: libraryRoot) {
                            let destURL = URL(fileURLWithPath: file.destinationPath)
                            try? FileManager.default.createDirectory(
                                at: destURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            // Clean up any alternative extensions of the same track to prevent stale or duplicate files (e.g. old fake .m4a)
                            let stemURL = destURL.deletingPathExtension()
                            let alternativeExtensions = ["m4a", "mp3", "wav", "flac", "aac", "ogg"]
                            for ext in alternativeExtensions {
                                let altURL = stemURL.appendingPathExtension(ext)
                                if altURL.path != destURL.path {
                                    try? FileManager.default.removeItem(at: altURL)
                                }
                            }
                            try? FileManager.default.removeItem(at: destURL)
                            do {
                                try FileManager.default.linkItem(at: sourceURL, to: destURL)
                            } catch {
                                try? FileManager.default.copyItem(at: sourceURL, to: destURL)
                            }
                            // For keepOriginals, file is already at destURL — update sync state directly
                            if FileManager.default.fileExists(atPath: destURL.path) {
                                let checksum = try TranscodeCache.sha256(of: destURL)
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
                                result.failedTracks.append((file.trackId, "Source file not found"))
                            }
                            cachedURL = nil  // Already handled above
                        } else {
                            cachedURL = nil
                            result.failedCount += 1
                            result.failedTracks.append((file.trackId, "No organized path for keepOriginals"))
                        }
                    case .aac248:
                        cachedURL = try await transcodeCache.ensureCached(track: track, bitrateKbps: 248, libraryRoot: libraryRoot)
                    case .aac320:
                        cachedURL = try await transcodeCache.ensureCached(track: track, bitrateKbps: 320, libraryRoot: libraryRoot)
                    }

                    // For aac248/aac320, link cached file to destination
                    if profile.transcodeModeEnum != .keepOriginals {
                        let bitrate: Int = profile.transcodeModeEnum == .aac320 ? 320 : 248
                        if let _ = cachedURL {
                            let destURL = TranscodeCache.buildProfilePath(
                                track: track,
                                libraryRoot: libraryRoot,
                                profileOutputFolder: profile.outputFolder,
                                transcodeMode: profile.transcodeModeEnum
                            )
                            // Clean up any alternative extensions of the same track to prevent stale or duplicate files (e.g. old fake .m4a)
                            let stemURL = destURL.deletingPathExtension()
                            let alternativeExtensions = ["m4a", "mp3", "wav", "flac", "aac", "ogg"]
                            for ext in alternativeExtensions {
                                let altURL = stemURL.appendingPathExtension(ext)
                                if altURL.path != destURL.path {
                                    try? FileManager.default.removeItem(at: altURL)
                                }
                            }

                            try transcodeCache.linkToProfile(
                                trackId: file.trackId,
                                bitrateKbps: bitrate,
                                destinationPath: destURL
                            )

                            // Update sync state
                            let checksum = try TranscodeCache.sha256(of: destURL)
                            let size = try FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int ?? 0

                            try await syncRepository.updateSyncState(
                                profileId: profileId,
                                trackId: file.trackId,
                                checksum: checksum,
                                size: size
                            )

                            result.syncedCount += 1
                            AppLogger.shared.info(
                                "Sync ok: track \(file.trackId) → \(destURL.path) (\(size) bytes, \(bitrate)k)",
                                source: "Sync"
                            )
                        } else {
                            result.failedCount += 1
                            result.failedTracks.append((file.trackId, "Transcode failed"))
                            AppLogger.shared.error(
                                "Sync failed (transcode returned nil): track \(file.trackId) \(file.artist) - \(file.title) at \(bitrate)k",
                                source: "Sync"
                            )
                        }
                    }
                }
            } catch {
                result.failedCount += 1
                result.failedTracks.append((file.trackId, error.localizedDescription))
                AppLogger.shared.error(
                    "Sync failed (exception): track \(file.trackId) \(file.artist) - \(file.title): \(error.localizedDescription)",
                    source: "Sync"
                )
            }

            processed += 1
            if cancellationRequested { break }
        }

        // 3. Generate M3U8 playlists (M3U8 gate — SYNC-v2-20)
        if profile.generateM3U8 {
            try await generatePlaylists(profileId: profileId, profile: profile, libraryRoot: libraryRoot)
        }

        currentFile = ""
        progress = 1.0

        // Finalise the Operations-tab row.
        if let operationId {
            let summary = "\(result.syncedCount) synchronisiert · \(result.failedCount) fehlgeschlagen"
            await MainActor.run {
                if cancellationRequested {
                    activityViewModel?.failOperation(id: operationId, error: "Abgebrochen — \(summary)")
                } else if result.failedCount > 0 && result.syncedCount == 0 {
                    activityViewModel?.failOperation(id: operationId, error: summary)
                } else {
                    activityViewModel?.completeOperation(id: operationId, detail: summary)
                }
            }
        }

        return result
    }

    // MARK: - Single-Track Retry (D-13 / SYNC-v2-17)

    /// Execute sync for a single track (for retry of failed tracks).
    func executeSyncSingleTrack(profileId: Int64, trackId: Int64) async throws -> SyncResult {
        guard let profile = try await syncRepository.fetch(id: profileId) else {
            throw SyncError.profileNotFound(profileId)
        }
        let fullPreview = try await previewSync(profileId: profileId)
        let libraryRoot = try await configRepository.getLibraryRoot() ?? ""

        var result = SyncResult()
        guard let filePreview = fullPreview.filesToAdd.first(where: { $0.trackId == trackId }) else {
            return result
        }

        if let track = try await trackRepository.fetchTrack(id: trackId) {
            // Determine if the track is actually syncable (has a local file/source)
            var isSyncable = false
            var candidatePaths: [String] = []
            if let op = track.organizedPath { candidatePaths.append(op) }
            if track.isLocal { candidatePaths.append(track.originalPath) }
            
            for candidate in candidatePaths {
                if TranscodeCache.resolveSourceURL(sourcePath: candidate, libraryRoot: libraryRoot) != nil {
                    isSyncable = true
                    break
                }
            }
            
            if !isSyncable {
                result.skippedCount = 1
                AppLogger.shared.warn(
                    "Retry skipped (no local file): track \(trackId) is stream-only or missing on-disk (tried \(candidatePaths))",
                    source: "Sync"
                )
                return result
            }

            do {
                switch profile.transcodeModeEnum {
                case .keepOriginals:
                    if let organizedPath = track.organizedPath,
                       let sourceURL = TranscodeCache.resolveSourceURL(sourcePath: organizedPath, libraryRoot: libraryRoot) {
                        let destURL = URL(fileURLWithPath: filePreview.destinationPath)
                        try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        // Clean up any alternative extensions of the same track to prevent stale or duplicate files (e.g. old fake .m4a)
                        let stemURL = destURL.deletingPathExtension()
                        let alternativeExtensions = ["m4a", "mp3", "wav", "flac", "aac", "ogg"]
                        for ext in alternativeExtensions {
                            let altURL = stemURL.appendingPathExtension(ext)
                            if altURL.path != destURL.path {
                                try? FileManager.default.removeItem(at: altURL)
                            }
                        }
                        try? FileManager.default.removeItem(at: destURL)
                        do { try FileManager.default.linkItem(at: sourceURL, to: destURL) } catch {
                            try? FileManager.default.copyItem(at: sourceURL, to: destURL)
                        }
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            let checksum = try TranscodeCache.sha256(of: destURL)
                            let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
                            try await syncRepository.updateSyncState(
                                profileId: profileId, trackId: trackId, checksum: checksum, size: size
                            )
                            result.syncedCount = 1
                        } else {
                            result.failedCount = 1
                            result.failedTracks.append((trackId, "Source file not found"))
                        }
                    } else {
                        result.failedCount = 1
                        result.failedTracks.append((trackId, "No organized path"))
                    }
                case .aac248:
                    if let url = try await transcodeCache.ensureCached(track: track, bitrateKbps: 248, libraryRoot: libraryRoot) {
                        let destURL = TranscodeCache.buildProfilePath(
                            track: track, libraryRoot: libraryRoot,
                            profileOutputFolder: profile.outputFolder,
                            transcodeMode: profile.transcodeModeEnum
                        )
                        // Clean up any alternative extensions of the same track to prevent stale or duplicate files
                        let stemURL = destURL.deletingPathExtension()
                        let alternativeExtensions = ["m4a", "mp3", "wav", "flac", "aac", "ogg"]
                        for ext in alternativeExtensions {
                            let altURL = stemURL.appendingPathExtension(ext)
                            if altURL.path != destURL.path {
                                try? FileManager.default.removeItem(at: altURL)
                            }
                        }
                        try transcodeCache.linkToProfile(trackId: trackId, bitrateKbps: 248, destinationPath: destURL)
                        let checksum = try TranscodeCache.sha256(of: url)
                        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                        try await syncRepository.updateSyncState(
                            profileId: profileId, trackId: trackId, checksum: checksum, size: size
                        )
                        result.syncedCount = 1
                        AppLogger.shared.info("Retry ok: track \(trackId) at 248k", source: "Sync")
                    } else {
                        result.failedCount = 1
                        result.failedTracks.append((trackId, "Transcode failed"))
                        AppLogger.shared.error("Retry failed (transcode returned nil): track \(trackId) at 248k", source: "Sync")
                    }
                case .aac320:
                    if let url = try await transcodeCache.ensureCached(track: track, bitrateKbps: 320, libraryRoot: libraryRoot) {
                        let destURL = TranscodeCache.buildProfilePath(
                            track: track, libraryRoot: libraryRoot,
                            profileOutputFolder: profile.outputFolder,
                            transcodeMode: profile.transcodeModeEnum
                        )
                        // Clean up any alternative extensions of the same track to prevent stale or duplicate files
                        let stemURL = destURL.deletingPathExtension()
                        let alternativeExtensions = ["m4a", "mp3", "wav", "flac", "aac", "ogg"]
                        for ext in alternativeExtensions {
                            let altURL = stemURL.appendingPathExtension(ext)
                            if altURL.path != destURL.path {
                                try? FileManager.default.removeItem(at: altURL)
                            }
                        }
                        try transcodeCache.linkToProfile(trackId: trackId, bitrateKbps: 320, destinationPath: destURL)
                        let checksum = try TranscodeCache.sha256(of: url)
                        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                        try await syncRepository.updateSyncState(
                            profileId: profileId, trackId: trackId, checksum: checksum, size: size
                        )
                        result.syncedCount = 1
                        AppLogger.shared.info("Retry ok: track \(trackId) at 320k", source: "Sync")
                    } else {
                        result.failedCount = 1
                        result.failedTracks.append((trackId, "Transcode failed"))
                        AppLogger.shared.error("Retry failed (transcode returned nil): track \(trackId) at 320k", source: "Sync")
                    }
                }
            } catch {
                result.failedCount = 1
                result.failedTracks.append((trackId, error.localizedDescription))
            }
        }
        return result
    }

    // MARK: - M3U8 Generation

    /// Generate playlist files for each playlist in the profile (Rockbox/Doppi).
    private func generatePlaylists(profileId: Int64, profile: SyncProfile, libraryRoot: String) async throws {
        let playlists = try await syncRepository.fetchProfilePlaylists(profileId: profileId)
        let profileDir = URL(fileURLWithPath: profile.outputFolder)

        for playlist in playlists {
            let playlistRepo = PlaylistRepository(database: syncRepository.databaseWriter)
            let tracks = try await playlistRepo.fetchTracks(playlistId: playlist.id!)

            var m3u = "#EXTM3U\n"
            for track in tracks {
                let duration = track.duration ?? 0
                let destPath = TranscodeCache.buildProfilePath(
                    track: track,
                    libraryRoot: libraryRoot,
                    profileOutputFolder: profile.outputFolder,
                    transcodeMode: profile.transcodeModeEnum
                )
                
                // Only include track if it physically exists on the device destination (skipped or missing tracks are omitted)
                let fileURL = URL(fileURLWithPath: destPath.path)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    continue
                }

                let isDoppi = profile.playlistFormatEnum == .doppi

                // Make path relative to profile root or absolute depending on format
                var fullPath: String
                if profile.playlistFormatEnum == .rockbox {
                    if profile.outputFolder.hasPrefix("/Volumes/") {
                        // Extract mount point prefix (e.g. /Volumes/IPOD)
                        let components = profile.outputFolder.split(separator: "/")
                        if components.count >= 2 {
                            let volumePrefix = "/\(components[0])/\(components[1])"
                            if destPath.path.hasPrefix(volumePrefix) {
                                fullPath = String(destPath.path.dropFirst(volumePrefix.count))
                            } else {
                                let relativePath = destPath.path.replacingOccurrences(of: profileDir.path + "/", with: "")
                                let prefix = profile.playlistPathPrefix
                                fullPath = prefix.isEmpty ? relativePath : "\(prefix)/\(relativePath)"
                            }
                        } else {
                            let relativePath = destPath.path.replacingOccurrences(of: profileDir.path + "/", with: "")
                            let prefix = profile.playlistPathPrefix
                            fullPath = prefix.isEmpty ? relativePath : "\(prefix)/\(relativePath)"
                        }
                    } else {
                        let relativePath = destPath.path.replacingOccurrences(of: profileDir.path + "/", with: "")
                        let prefix = profile.playlistPathPrefix
                        fullPath = prefix.isEmpty ? relativePath : "\(prefix)/\(relativePath)"
                    }
                } else {
                    // Doppi or other formats: relative to output folder with a leading slash
                    let relativePath = destPath.path.replacingOccurrences(of: profileDir.path + "/", with: "")
                    let prefix = profile.playlistPathPrefix
                    fullPath = prefix.isEmpty ? relativePath : "\(prefix)/\(relativePath)"
                    if !fullPath.hasPrefix("/") {
                        fullPath = "/" + fullPath
                    }
                }

                // For Doppi matching and Rockbox presentation, extract the original mixed-case
                // metadata tags directly from the synced file itself, rather than relying on
                // the database values which are entirely normalized to lowercase.
                var artist = track.artist
                var title = track.title
                var albumArtist: String? = nil
                
                let asset = AVAsset(url: fileURL)
                if let commonItems = try? await asset.load(.commonMetadata) {
                    for item in commonItems {
                        if item.commonKey == .commonKeyArtist {
                            if let val = try? await item.load(.stringValue),
                               !val.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                                artist = val.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                            }
                        } else if item.commonKey == .commonKeyTitle {
                            if let val = try? await item.load(.stringValue),
                               !val.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                                title = val.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                            }
                        }
                    }
                }

                // Load album artist from iTunes/ID3 format-specific metadata to match Doppi's grouping preferences
                if let allItems = try? await asset.load(.metadata) {
                    let itunesAlbumArtists = AVMetadataItem.metadataItems(from: allItems, filteredByIdentifier: .iTunesMetadataAlbumArtist)
                    let id3Bands = AVMetadataItem.metadataItems(from: allItems, filteredByIdentifier: .id3MetadataBand)
                    if let rawAlbumArtist = itunesAlbumArtists.first?.stringValue ?? id3Bands.first?.stringValue,
                       !rawAlbumArtist.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                        albumArtist = rawAlbumArtist.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    }
                }
                
                // Casing fallback for title: if title is still the lowercase track.title and matches the file's name stem,
                // we can use the capitalized filename stem as a high-quality fallback!
                if title == track.title {
                    let fileStem = fileURL.deletingPathExtension().lastPathComponent
                    if fileStem.lowercased() == track.title.lowercased() {
                        title = fileStem
                    }
                }
                
                let displayArtist = isDoppi ? (albumArtist ?? artist) : artist
                let infoString: String
                if isDoppi {
                    infoString = displayArtist.isEmpty ? title : "\(title) - \(displayArtist)"
                } else {
                    infoString = artist.isEmpty ? title : "\(artist) - \(title)"
                }
                m3u += "#EXTINF:\(duration),\(infoString)\n"
                m3u += "\(fullPath)\n"
            }

            // Apply precomposed NFC Unicode normalization to the entire playlist contents
            // to resolve diacritic mismatch errors in Rockbox/FAT32 and iOS Doppi.
            let normalizedM3U = m3u.precomposedStringWithCanonicalMapping

            let isDoppi = profile.playlistFormatEnum == .doppi
            let extensionStr = isDoppi ? ".m3u" : ".m3u8"
            let playlistName = PathSanitizer.sanitizeComponent(playlist.name) + extensionStr
            let playlistPath = profileDir.appendingPathComponent(playlistName)
            
            try normalizedM3U.write(to: playlistPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Helpers

    private func estimateFileSize(track: Track) -> Int64 {
        // Estimate: 248kbps * duration = bytes
        let duration = Double(track.duration ?? 240)  // default 4 min
        return Int64(248_000 / 8 * duration)
    }
}
