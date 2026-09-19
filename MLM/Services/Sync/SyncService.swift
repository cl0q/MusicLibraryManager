import Foundation
import AVFoundation
import CryptoKit

/// Profile-based device sync service.
///
/// Mirrors the Rust `SyncService`. Resolves profile content (manual tracks +
/// playlists + rules), creates preview diffs, executes file sync with
/// ReplayGain tagging, and generates M3U8 playlists.
@Observable
final class SyncService {

    // MARK: - Constants

    /// Target integrated loudness for the "normalize loudness" export option.
    /// -14 LUFS matches the reference level used by Spotify/YouTube/Tidal, so
    /// normalized exports feel as loud as streaming without clipping.
    static let loudnessTargetLUFS: Double = -14.0

    // MARK: - iOS Layout Helpers (IOS_SIDECAR_PLAN §2)

    /// The folder under which audio files are written for a profile.
    ///
    /// `.ios` profiles use a fixed layout with audio under `<root>/Music/`,
    /// independent of `playlist_path_prefix`. Rockbox/Doppi write directly
    /// into `<root>` (the profile output folder).
    static func musicRootFolder(for profile: SyncProfile) -> String {
        if profile.playlistFormatEnum == .ios {
            return (profile.outputFolder as NSString).appendingPathComponent("Music")
        }
        return profile.outputFolder
    }

    /// The folder into which `.m3u8` playlist files are written.
    ///
    /// `.ios` profiles put playlists under `<root>/Playlists/`.
    /// Rockbox/Doppi write them into `<root>` (the profile output folder).
    static func playlistsFolder(for profile: SyncProfile) -> String {
        if profile.playlistFormatEnum == .ios {
            return (profile.outputFolder as NSString).appendingPathComponent("Playlists")
        }
        return profile.outputFolder
    }

    // MARK: - Types

    struct PreviewResult {
        var filesToAdd: [FilePreview] = []
        var filesToRemove: [FilePreview] = []
        var totalNewSize: Int64 = 0
        var totalRemoveSize: Int64 = 0
        var deviceAvailableSpace: Int64 = 0
        var hasSufficientSpace: Bool = true
        var isDeviceConnected: Bool = true
    }

    /// Kept as an alias while the sync presentation migrates to PreviewResult.
    typealias SyncPreview = PreviewResult

    struct FilePreview: Identifiable {
        let id: Int64
        let trackId: Int64
        let title: String
        let artist: String
        let album: String
        let size: Int64
        let destinationPath: String
    }

    struct SyncFailure: Identifiable, Equatable {
        let trackId: Int64
        let title: String
        let artist: String
        let reason: String

        var id: Int64 { trackId }
    }

    struct SyncResult {
        var syncedCount: Int = 0
        var failedCount: Int = 0
        var skippedCount: Int = 0
        var failedTracks: [SyncFailure] = []
        var wasCancelled: Bool = false
    }

    /// Cached previews are kept per profile so the UI can show the most
    /// recent plan while a cancellable background refresh replaces it.
    struct CachedPreview {
        let result: PreviewResult
        let inputHash: String
        let computedAt: Date
        let deviceWasConnected: Bool

        var preview: PreviewResult { result }
    }

    private struct PreviewInput {
        let profile: SyncProfile
        let libraryRoot: String
        let trackIds: Set<Int64>
        let syncedTrackIds: Set<Int64>
        let tracksByID: [Int64: Track]
        let isDeviceConnected: Bool
        let hash: String

        var total: Int { trackIds.count + syncedTrackIds.subtracting(trackIds).count }
    }

    // MARK: - State

    private(set) var isRunning = false
    private(set) var progress: Double = 0
    private(set) var currentFile: String = ""
    private(set) var syncTurboLevel: SyncTurboLevel = .standard

    // MARK: - Cancellation + Progress Tracking (D-14)

    private(set) var cancellationRequested: Bool = false
    private(set) var isPaused: Bool = false
    private(set) var processed: Int = 0
    private(set) var total: Int = 0

    private var previewCache: [Int64: CachedPreview] = [:]

    func cancelSync() {
        cancellationRequested = true
        isPaused = false
    }

    func pauseSync() {
        guard isRunning else { return }
        isPaused = true
    }

    func resumeSync() {
        isPaused = false
    }

    func cachedPreview(profileId: Int64) -> CachedPreview? {
        previewCache[profileId]
    }

    func invalidatePreview(profileId: Int64) {
        previewCache.removeValue(forKey: profileId)
    }

    /// Update the sync turbo level preference
    func setSyncTurboLevel(_ level: SyncTurboLevel) {
        syncTurboLevel = level
        UserDefaults.standard.set(level.rawValue, forKey: "sync_turbo_level")
        AppLogger.shared.info(
            "Background processing set to \(level.displayName) (\(level.workerCount()) workers)",
            source: "Sync"
        )
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
        
        if let rawValue = UserDefaults.standard.string(forKey: "sync_turbo_level"),
           let level = SyncTurboLevel(rawValue: rawValue) {
            self.syncTurboLevel = level
        } else {
            self.syncTurboLevel = .standard
        }
    }

    // MARK: - Preview

    /// Resolve a profile's sync plan. The input hash lets callers reuse a
    /// result only while profile settings, selected tracks, source metadata,
    /// sync state, and device availability are unchanged.
    ///
    /// The caller can display cached results immediately, then use the
    /// progress callback while this calculation refreshes in the background.
    func previewSync(
        profileId: Int64,
        forceRefresh: Bool = false,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> PreviewResult {
        try Task.checkCancellation()
        let input = try await makePreviewInput(profileId: profileId)
        try Task.checkCancellation()

        if !forceRefresh,
           let cached = previewCache[profileId],
           cached.inputHash == input.hash {
            progress?(input.total, input.total)
            return cached.result
        }

        let profile = input.profile
        let libraryRoot = input.libraryRoot
        let trackIds = input.trackIds
        let syncedTrackIds = input.syncedTrackIds
        let tracksByID = input.tracksByID
        let isDeviceConnected = input.isDeviceConnected
        let outputURL = URL(fileURLWithPath: profile.outputFolder)
        let previewTotal = input.total
        progress?(0, previewTotal)

        let invalidDestinationTrackIds = try await invalidDestinationTrackIds(
            trackIds: trackIds,
            syncedTrackIds: syncedTrackIds,
            tracksByID: tracksByID,
            profile: profile,
            libraryRoot: libraryRoot
        )

        var preview = PreviewResult()
        preview.isDeviceConnected = isDeviceConnected
        let removeTrackIds = syncedTrackIds.subtracting(trackIds)
        var previewProcessed = 0

        // Files to add (in profile but not yet synced, OR physical file is missing/stale/corrupted on the destination drive)
        for trackId in trackIds.sorted() {
            try Task.checkCancellation()
            defer {
                previewProcessed += 1
                progress?(previewProcessed, previewTotal)
            }

            if let track = tracksByID[trackId] {
                let destPath = TranscodeCache.buildProfilePath(
                    track: track,
                    libraryRoot: libraryRoot,
                    profileOutputFolder: Self.musicRootFolder(for: profile),
                    transcodeMode: profile.transcodeModeEnum
                )

                let needsSync = !syncedTrackIds.contains(trackId)
                    || !FileManager.default.fileExists(atPath: destPath.path)
                    || invalidDestinationTrackIds.contains(trackId)

                if needsSync {
                    let size = estimateFileSize(
                        track: track,
                        profile: profile,
                        libraryRoot: libraryRoot
                    )
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
        for trackId in removeTrackIds.sorted() {
            try Task.checkCancellation()
            defer {
                previewProcessed += 1
                progress?(previewProcessed, previewTotal)
            }

            if let track = tracksByID[trackId] {
                let destPath = TranscodeCache.buildProfilePath(
                    track: track,
                    libraryRoot: libraryRoot,
                    profileOutputFolder: Self.musicRootFolder(for: profile),
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
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: outputURL.path) {
            let available = (attrs[.systemFreeSize] as? Int64) ?? 0
            preview.deviceAvailableSpace = available
            preview.hasSufficientSpace = available >= preview.totalNewSize + Self.spaceBuffer
        } else {
            preview.hasSufficientSpace = false
        }

        try Task.checkCancellation()
        previewCache[profileId] = CachedPreview(
            result: preview,
            inputHash: input.hash,
            computedAt: Date(),
            deviceWasConnected: isDeviceConnected
        )

        return preview
    }

    private func makePreviewInput(profileId: Int64) async throws -> PreviewInput {
        guard let profile = try await syncRepository.fetch(id: profileId) else {
            throw SyncError.profileNotFound(profileId)
        }

        let outputURL = URL(fileURLWithPath: profile.outputFolder)
        let isDeviceConnected = FileManager.default.fileExists(atPath: outputURL.path)

        let rules = try await syncRepository.fetchProfileRules(profileId: profileId)
        let trackIds = try await trackRepository.fetchTrackIdsForSyncProfile(
            profileId: profileId,
            rules: rules
        )

        let libraryRoot = try await configRepository.getLibraryRoot() ?? ""
        let syncState = try await syncRepository.fetchSyncState(profileId: profileId)
        let syncedTrackIds = Set(syncState.map(\.trackId))
        let tracks = try await trackRepository.fetchTracks(ids: trackIds.union(syncedTrackIds))
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
            track.id.map { ($0, track) }
        })

        return PreviewInput(
            profile: profile,
            libraryRoot: libraryRoot,
            trackIds: trackIds,
            syncedTrackIds: syncedTrackIds,
            tracksByID: tracksByID,
            isDeviceConnected: isDeviceConnected,
            hash: Self.previewInputHash(
                profile: profile,
                libraryRoot: libraryRoot,
                trackIds: trackIds,
                syncedTrackIds: syncedTrackIds,
                tracksByID: tracksByID,
                isDeviceConnected: isDeviceConnected
            )
        )
    }

    /// ffprobe can be expensive on networked drives. Keep it bounded by the
    /// same processing preference used elsewhere in sync work.
    private func invalidDestinationTrackIds(
        trackIds: Set<Int64>,
        syncedTrackIds: Set<Int64>,
        tracksByID: [Int64: Track],
        profile: SyncProfile,
        libraryRoot: String
    ) async throws -> Set<Int64> {
        guard profile.transcodeModeEnum != .keepOriginals else { return [] }

        let destinations = trackIds.sorted().compactMap { trackId -> (Int64, URL)? in
            guard syncedTrackIds.contains(trackId), let track = tracksByID[trackId] else { return nil }
            let destination = TranscodeCache.buildProfilePath(
                track: track,
                libraryRoot: libraryRoot,
                profileOutputFolder: Self.musicRootFolder(for: profile),
                transcodeMode: profile.transcodeModeEnum
            )
            guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
            return (trackId, destination)
        }
        guard !destinations.isEmpty else { return [] }

        let workerCount = min(syncTurboLevel.workerCount(), destinations.count)
        let cache = transcodeCache
        return try await withThrowingTaskGroup(of: Int64?.self) { group in
            var nextIndex = 0

            func addNextDestination() {
                let destination = destinations[nextIndex]
                nextIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    return await cache.verifyCacheCodec(destination.1) ? nil : destination.0
                }
            }

            for _ in 0..<workerCount {
                addNextDestination()
            }

            var invalidTrackIds = Set<Int64>()
            while let trackId = try await group.next() {
                try Task.checkCancellation()
                if let trackId {
                    invalidTrackIds.insert(trackId)
                }
                if nextIndex < destinations.count {
                    addNextDestination()
                }
            }
            return invalidTrackIds
        }
    }

    private static func previewInputHash(
        profile: SyncProfile,
        libraryRoot: String,
        trackIds: Set<Int64>,
        syncedTrackIds: Set<Int64>,
        tracksByID: [Int64: Track],
        isDeviceConnected: Bool
    ) -> String {
        var components = [
            profile.outputFolder,
            profile.playlistPathPrefix,
            profile.generateM3U8 ? "1" : "0",
            profile.transcodeMode,
            profile.fat32SafePaths ? "1" : "0",
            profile.cleanupRemovedFiles ? "1" : "0",
            profile.playlistFormat,
            profile.normalizeLoudness ? "1" : "0",
            libraryRoot,
            isDeviceConnected ? "1" : "0"
        ]

        for trackId in trackIds.union(syncedTrackIds).sorted() {
            let membership = trackIds.contains(trackId) ? "included" : "removed"
            let syncState = syncedTrackIds.contains(trackId) ? "synced" : "not-synced"
            guard let track = tracksByID[trackId] else {
                components.append("\(trackId)|\(membership)|\(syncState)|missing")
                continue
            }
            components.append([
                String(trackId),
                membership,
                syncState,
                track.artist,
                track.album,
                track.title,
                track.format,
                track.originalPath,
                track.organizedPath ?? "",
                String(track.bitrate ?? 0),
                String(track.duration ?? 0)
            ].joined(separator: "|"))
        }

        let digest = SHA256.hash(data: Data(components.joined(separator: "\u{0}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Parallel Sync Helpers

    enum FileSyncOutcome: Sendable {
        case synced(Int64, Int) // trackId, size
        case skipped(Int64)
        case failed(Int64, String) // trackId, error description
    }

    private func incrementProcessed(currentFile: String, operationId: UUID?) async {
        await MainActor.run {
            self.processed += 1
            self.currentFile = currentFile
            self.progress = Double(self.processed) / Double(max(self.total, 1))
            if let operationId {
                self.activityViewModel?.updateProgress(
                    id: operationId,
                    progress: self.progress,
                    detail: "\(self.processed) / \(self.total) — \(currentFile)"
                )
            }
        }
    }

    private func reportCurrentFile(_ currentFile: String, operationId: UUID?) async {
        await MainActor.run {
            self.currentFile = currentFile
            if let operationId {
                self.activityViewModel?.updateProgress(
                    id: operationId,
                    progress: self.progress,
                    detail: "\(self.processed) / \(self.total) — \(currentFile)"
                )
            }
        }
    }

    private func waitForSyncPermission() async throws {
        while isPaused {
            try Task.checkCancellation()
            if cancellationRequested {
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        if cancellationRequested {
            throw CancellationError()
        }
    }

    private func syncSingleFile(
        file: FilePreview,
        profileId: Int64,
        profile: SyncProfile,
        libraryRoot: String,
        operationId: UUID?
    ) async throws -> FileSyncOutcome {
        try await waitForSyncPermission()
        let trackName = "\(file.artist) – \(file.title)"
        
        guard let track = try await trackRepository.fetchTrack(id: file.trackId) else {
            await incrementProcessed(currentFile: "Failed: \(trackName)", operationId: operationId)
            return .failed(file.trackId, "Track metadata not found in database")
        }

        let operation = profile.transcodeModeEnum == .keepOriginals ? "Copying" : "Transcoding"
        await reportCurrentFile("\(operation): \(trackName)", operationId: operationId)

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
            AppLogger.shared.warn(
                "Sync skipped (no local file): track \(file.trackId) \(file.artist) - \(file.title) is stream-only or missing on-disk",
                source: "Sync"
            )
            await incrementProcessed(currentFile: "Skipped: \(trackName)", operationId: operationId)
            return .skipped(file.trackId)
        }

        // Transcode-mode branching (SYNC-v2-19)
        let cachedURL: URL?

        // Loudness normalization gain (v24): when enabled on the profile and
        // the track has a measured integrated loudness, compute the dB gain
        // needed to reach the -14 LUFS target. Baked into the AAC on transcode
        // so phone players without ReplayGain still play at an even level.
        // Only meaningful for AAC transcode modes (keepOriginals links the raw
        // file untouched). Clamped to avoid extreme pumping on near-silent or
        // hot masters.
        let normalizationGainDB: Double? = {
            guard profile.normalizeLoudness,
                  profile.transcodeModeEnum != .keepOriginals,
                  let lufs = track.lufsI, lufs > -70 else { return nil }
            let raw = SyncService.loudnessTargetLUFS - lufs
            return max(-24.0, min(12.0, raw))
        }()

        // WP-B: artwork resize only applies to AAC transcode modes.
        // keepOriginals links the untouched library file with its full-size cover — deliberate.
        let artworkMaxPx: Int? = profile.artworkModeEnum == .resize250 ? 250 : nil

        switch profile.transcodeModeEnum {
        case .keepOriginals:
            try await waitForSyncPermission()
            // Bypass TranscodeCache — link original file directly (no transcode).
            // Artwork resize is deliberately NOT applied here: keepOriginals
            // preserves the library file untouched including its full-size cover.
            if let organizedPath = track.organizedPath,
               let sourceURL = TranscodeCache.resolveSourceURL(sourcePath: organizedPath, libraryRoot: libraryRoot) {
                let destURL = URL(fileURLWithPath: file.destinationPath)
                try FileManager.default.createDirectory(
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
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)
                }
                // For keepOriginals, file is already at destURL — update sync state directly
                if FileManager.default.fileExists(atPath: destURL.path) {
                    // Embed mlm_uuid into the synced file (best-effort, never fails sync)
                    await embedMlmUuid(track: track, destinationURL: destURL)

                    let checksum = try TranscodeCache.sha256(of: destURL)
                    let size = try FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int ?? 0
                    try await syncRepository.updateSyncState(
                        profileId: profileId,
                        trackId: file.trackId,
                        checksum: checksum,
                        size: size
                    )
                    await incrementProcessed(currentFile: "Copying: \(trackName)", operationId: operationId)
                    return .synced(file.trackId, size)
                } else {
                    await incrementProcessed(currentFile: "Failed: \(trackName)", operationId: operationId)
                    return .failed(file.trackId, "Source file not found")
                }
            } else {
                await incrementProcessed(currentFile: "Failed: \(trackName)", operationId: operationId)
                return .failed(file.trackId, "No organized path for keepOriginals")
            }
        case .aac248:
            try await waitForSyncPermission()
            cachedURL = try await transcodeCache.ensureCached(track: track, bitrateKbps: 248, libraryRoot: libraryRoot, normalizationGainDB: normalizationGainDB, mlmUuid: track.mlmUuid, artworkMaxPx: artworkMaxPx)
        case .aac320:
            try await waitForSyncPermission()
            cachedURL = try await transcodeCache.ensureCached(track: track, bitrateKbps: 320, libraryRoot: libraryRoot, normalizationGainDB: normalizationGainDB, mlmUuid: track.mlmUuid, artworkMaxPx: artworkMaxPx)
        }

        // For aac248/aac320, link cached file to destination
        if profile.transcodeModeEnum != .keepOriginals {
            try await waitForSyncPermission()
            let bitrate: Int = profile.transcodeModeEnum == .aac320 ? 320 : 248
            if let cachedURL {
                let destURL = TranscodeCache.buildProfilePath(
                    track: track,
                    libraryRoot: libraryRoot,
                    profileOutputFolder: Self.musicRootFolder(for: profile),
                    transcodeMode: profile.transcodeModeEnum
                )

                try transcodeCache.linkToProfile(
                    trackId: file.trackId,
                    bitrateKbps: bitrate,
                    destinationPath: destURL,
                    normalized: normalizationGainDB != nil,
                    artworkMaxPx: artworkMaxPx
                )

                // linkToProfile succeeded — safe to remove alternative-extension siblings.
                let stemURL = destURL.deletingPathExtension()
                let alternativeExtensions = ["m4a", "mp3", "wav", "flac", "aac", "ogg"]
                for ext in alternativeExtensions {
                    let altURL = stemURL.appendingPathExtension(ext)
                    if altURL.path != destURL.path {
                        try? FileManager.default.removeItem(at: altURL)
                    }
                }

                // UUID is already embedded into the cache file by ensureCached(mlmUuid:),
                // so the hardlink/copy to the device carries the tag without a second
                // ffmpeg pass on the device volume.

                // Hash the local cache file (byte-identical to the device copy)
                // to avoid reading the entire file back over USB 2.
                let checksum = try TranscodeCache.sha256(of: cachedURL)
                let size = try FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int ?? 0

                try await syncRepository.updateSyncState(
                    profileId: profileId,
                    trackId: file.trackId,
                    checksum: checksum,
                    size: size
                )

                AppLogger.shared.info(
                    "Sync ok: track \(file.trackId) → \(destURL.path) (\(size) bytes, \(bitrate)k)",
                    source: "Sync"
                )
                await incrementProcessed(currentFile: "Copying: \(trackName)", operationId: operationId)
                return .synced(file.trackId, size)
            } else {
                AppLogger.shared.error(
                    "Sync failed (transcode returned nil): track \(file.trackId) \(file.artist) - \(file.title) at \(bitrate)k",
                    source: "Sync"
                )
                await incrementProcessed(currentFile: "Failed: \(trackName)", operationId: operationId)
                return .failed(file.trackId, "Transcode failed")
            }
        }
        
        return .failed(file.trackId, "Unknown transcode mode")
    }

    // MARK: - Execute

    /// Execute sync for a profile.
    func executeSync(profileId: Int64) async throws -> SyncResult {
        guard let profile = try await syncRepository.fetch(id: profileId) else {
            throw SyncError.profileNotFound(profileId)
        }

        let preview = try await previewSync(profileId: profileId)
        if !preview.isDeviceConnected,
           preview.filesToAdd.isEmpty,
           preview.filesToRemove.isEmpty {
            return SyncResult()
        }
        guard preview.hasSufficientSpace else {
            throw SyncError.insufficientSpace(
                needed: preview.totalNewSize,
                available: preview.deviceAvailableSpace
            )
        }

        // Reset cancellation flag + progress tracking at start (D-14)
        cancellationRequested = false
        isPaused = false
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
                detail: "0 / \(total)",
                retry: { [weak self] in _ = try? await self?.executeSync(profileId: profileId) }
            )
        }

        // 1. Remove stale files (cleanup-deletion branch — D-04 / SYNC-v2-05)
        for file in preview.filesToRemove {
            do {
                try await waitForSyncPermission()
            } catch is CancellationError {
                result.wasCancelled = true
                break
            }
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
            await incrementProcessed(
                currentFile: "Removing: \(file.artist) – \(file.title)",
                operationId: operationId
            )
        }

        // 2. Sync new files
        let libraryRoot = try await finalisingOperationOnThrow(operationId) { try await configRepository.getLibraryRoot() ?? "" }
        let workerCount = syncTurboLevel.workerCount()
        AppLogger.shared.info(
            "Syncing new files: \(preview.filesToAdd.count) tracks with \(workerCount) workers (background processing: \(syncTurboLevel.displayName))",
            source: "Sync"
        )

        let limiter = ConcurrencyLimiter(maxConcurrency: workerCount)
        var outcomes: [FileSyncOutcome] = []
        outcomes.reserveCapacity(preview.filesToAdd.count)

        outcomes = await withTaskGroup(of: FileSyncOutcome.self) { group in
            for file in preview.filesToAdd {
                group.addTask {
                    // Check cancellation before acquiring a slot
                    guard !self.cancellationRequested else {
                        return .failed(file.trackId, "Cancelled")
                    }
                    do {
                        return try await limiter.run {
                            try await self.syncSingleFile(
                                file: file,
                                profileId: profileId,
                                profile: profile,
                                libraryRoot: libraryRoot,
                                operationId: operationId
                            )
                        }
                    } catch is CancellationError {
                        return .failed(file.trackId, "Cancelled")
                    } catch {
                        AppLogger.shared.error(
                            "Sync failed for \(file.artist) - \(file.title): \(error.localizedDescription)",
                            source: "Sync"
                        )
                        await self.incrementProcessed(
                            currentFile: "Failed: \(file.artist) – \(file.title)",
                            operationId: operationId
                        )
                        return .failed(file.trackId, Self.userFacingFailureReason(error))
                    }
                }
            }

            var collected: [FileSyncOutcome] = []
            collected.reserveCapacity(preview.filesToAdd.count)
            for await outcome in group {
                collected.append(outcome)
                if self.cancellationRequested {
                    group.cancelAll()
                    break
                }
            }
            return collected
        }

        if cancellationRequested {
            result.wasCancelled = true
        }

        // Aggregate outcomes
        let previewFilesByID = Dictionary(uniqueKeysWithValues: preview.filesToAdd.map { ($0.trackId, $0) })
        for outcome in outcomes {
            switch outcome {
            case .synced:
                result.syncedCount += 1
            case .skipped:
                result.skippedCount += 1
            case .failed(let id, let errMsg):
                if errMsg == "Cancelled" {
                    result.skippedCount += 1
                    result.wasCancelled = true
                } else {
                    result.failedCount += 1
                    let file = previewFilesByID[id]
                    result.failedTracks.append(SyncFailure(
                        trackId: id,
                        title: file?.title ?? "Unknown track",
                        artist: file?.artist ?? "Unknown artist",
                        reason: errMsg
                    ))
                }
            }
        }

        // 3. Generate M3U8 playlists (M3U8 gate — SYNC-v2-20)
        if profile.generateM3U8 && !result.wasCancelled {
            try await finalisingOperationOnThrow(operationId) { try await generatePlaylists(profileId: profileId, profile: profile, libraryRoot: libraryRoot) }
        }

        // 4. Write mlm-library.json manifest for iOS dialect profiles
        if profile.playlistFormatEnum == .ios && !result.wasCancelled {
            try await finalisingOperationOnThrow(operationId) { try await generateManifest(profileId: profileId, profile: profile, libraryRoot: libraryRoot) }
        }

        currentFile = ""
        progress = 1.0

        // Finalise the Operations-tab row.
        if let operationId {
            let summary = "\(result.syncedCount) synced · \(result.failedCount) failed"
            let wasCancelled = result.wasCancelled || cancellationRequested
            let onlyFailures = result.failedCount > 0 && result.syncedCount == 0
            await MainActor.run {
                if wasCancelled {
                    activityViewModel?.cancelOperation(id: operationId, detail: "Cancelled — \(summary)")
                } else if onlyFailures {
                    activityViewModel?.failOperation(id: operationId, error: summary)
                } else {
                    activityViewModel?.completeOperation(id: operationId, detail: summary)
                }
            }
        }

        return result
    }

    /// Fails the Activity operation when `work` throws, then rethrows. Without this a throw between
    /// registration and the finalisation block leaves the row permanently `.running` — the caller cannot
    /// terminalise it because `operationId` is local to `executeSync`.
    private func finalisingOperationOnThrow<T>(
        _ operationId: UUID?,
        _ work: () async throws -> T
    ) async rethrows -> T {
        do { return try await work() }
        catch {
            if let operationId {
                await MainActor.run {
                    self.activityViewModel?.failOperation(id: operationId, error: error.localizedDescription)
                }
            }
            throw error
        }
    }

    // MARK: - Single-Track Retry (D-13 / SYNC-v2-17)

    /// Execute sync for a single track (for retry of failed tracks).
    func executeSyncSingleTrack(profileId: Int64, trackId: Int64) async throws -> SyncResult {
        guard let profile = try await syncRepository.fetch(id: profileId) else {
            throw SyncError.profileNotFound(profileId)
        }
        let libraryRoot = try await configRepository.getLibraryRoot() ?? ""

        var result = SyncResult()
        guard let track = try await trackRepository.fetchTrack(id: trackId) else {
            return result
        }

        let destinationPath = TranscodeCache.buildProfilePath(
            track: track,
            libraryRoot: libraryRoot,
            profileOutputFolder: Self.musicRootFolder(for: profile),
            transcodeMode: profile.transcodeModeEnum
        ).path
        let filePreview = FilePreview(
            id: trackId,
            trackId: trackId,
            title: track.title,
            artist: track.artist,
            album: track.album,
            size: estimateFileSize(track: track, profile: profile, libraryRoot: libraryRoot),
            destinationPath: destinationPath
        )

        cancellationRequested = false
        isPaused = false
        do {
            switch try await syncSingleFile(
                file: filePreview,
                profileId: profileId,
                profile: profile,
                libraryRoot: libraryRoot,
                operationId: nil
            ) {
            case .synced:
                result.syncedCount = 1
            case .skipped:
                result.skippedCount = 1
            case .failed(_, let reason):
                result.failedCount = 1
                result.failedTracks = [SyncFailure(
                    trackId: trackId,
                    title: track.title,
                    artist: track.artist,
                    reason: reason
                )]
            }
        } catch is CancellationError {
            result.wasCancelled = true
        } catch {
            result.failedCount = 1
            result.failedTracks = [SyncFailure(
                trackId: trackId,
                title: track.title,
                artist: track.artist,
                reason: Self.userFacingFailureReason(error)
            )]
        }
        return result
    }

    // MARK: - M3U8 Generation

    /// Generate playlist files for each playlist in the profile (Rockbox/Doppi/iOS).
    private func generatePlaylists(profileId: Int64, profile: SyncProfile, libraryRoot: String) async throws {
        let playlists = try await syncRepository.fetchProfilePlaylists(profileId: profileId)
        let profileDir = URL(fileURLWithPath: profile.outputFolder)
        let isIOS = profile.playlistFormatEnum == .ios

        // For the iOS dialect, ensure stable UUIDs on every playlist and track before writing.
        if isIOS {
            try await ensureMlmUuids(playlists: playlists)
        }

        let playlistRepo = PlaylistRepository(database: syncRepository.databaseWriter)
        var metadataMemo: [Int64: PlaylistTrackMemoEntry] = [:]
        for playlist in playlists {
            guard let playlistId = playlist.id else { continue }
            let tracks = try await playlistRepo.fetchTracks(playlistId: playlistId)

            var m3u = "#EXTM3U\n"
            if isIOS, let plUuid = playlist.mlmUuid {
                m3u += "#EXTMLM-PLAYLIST:\(plUuid)\n"
            }
            // Collect snapshot entries for iOS dialect (WP3)
            var snapshotEntries: [(uuid: String?, path: String)] = []
            for track in tracks {
                let duration = track.duration ?? 0
                let destPath = TranscodeCache.buildProfilePath(
                    track: track,
                    libraryRoot: libraryRoot,
                    profileOutputFolder: Self.musicRootFolder(for: profile),
                    transcodeMode: profile.transcodeModeEnum
                )

                let fileURL = URL(fileURLWithPath: destPath.path)
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
                } else if isIOS {
                    // iOS dialect: relative path from profile output root (includes Music/ prefix),
                    // no leading slash, independent of playlist_path_prefix (spec §2).
                    let relativePath = destPath.path.replacingOccurrences(of: profileDir.path + "/", with: "")
                    fullPath = relativePath
                } else {
                    // Doppi: relative to output folder with a leading slash
                    let relativePath = destPath.path.replacingOccurrences(of: profileDir.path + "/", with: "")
                    let prefix = profile.playlistPathPrefix
                    fullPath = prefix.isEmpty ? relativePath : "\(prefix)/\(relativePath)"
                    if !fullPath.hasPrefix("/") {
                        fullPath = "/" + fullPath
                    }
                }

                let loadMetadata: () async throws -> PlaylistTrackMemoEntry = {
                    // Only include track if it physically exists on the device destination (skipped or missing tracks are omitted)
                    guard FileManager.default.fileExists(atPath: fileURL.path) else {
                        return PlaylistTrackMemoEntry(exists: false, artist: track.artist, title: track.title, albumArtist: nil)
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

                    return PlaylistTrackMemoEntry(exists: true, artist: artist, title: title, albumArtist: albumArtist)
                }

                let memoEntry: PlaylistTrackMemoEntry
                if let trackId = track.id {
                    memoEntry = try await SyncService.memoizedMetadata(key: trackId, in: &metadataMemo, loader: loadMetadata)
                } else {
                    memoEntry = try await loadMetadata()
                }

                // Only include track if it physically exists on the device destination (skipped or missing tracks are omitted)
                guard memoEntry.exists else { continue }

                let displayArtist = isDoppi ? (memoEntry.albumArtist ?? memoEntry.artist) : memoEntry.artist
                let infoString: String
                if isDoppi {
                    infoString = displayArtist.isEmpty ? memoEntry.title : "\(memoEntry.title) - \(displayArtist)"
                } else {
                    infoString = memoEntry.artist.isEmpty ? memoEntry.title : "\(memoEntry.artist) - \(memoEntry.title)"
                }
                m3u += "#EXTINF:\(duration),\(infoString)\n"
                if isIOS, let trackUuid = track.mlmUuid {
                    m3u += "#EXTMLM:\(trackUuid)\n"
                }
                m3u += "\(fullPath)\n"
                // Record for snapshot (iOS dialect only)
                if isIOS {
                    snapshotEntries.append((uuid: track.mlmUuid, path: fullPath))
                }
            }

            // Apply precomposed NFC Unicode normalization to the entire playlist contents
            // to resolve diacritic mismatch errors in Rockbox/FAT32 and iOS Doppi.
            let normalizedM3U = m3u.precomposedStringWithCanonicalMapping

            let isDoppi = profile.playlistFormatEnum == .doppi
            let extensionStr = isDoppi ? ".m3u" : ".m3u8"
            let playlistName = PathSanitizer.sanitizeComponent(playlist.name) + extensionStr
            // iOS dialect writes playlists into <root>/Playlists/ (spec §2);
            // Rockbox/Doppi write into the profile output folder directly.
            let playlistDirURL = URL(fileURLWithPath: Self.playlistsFolder(for: profile))
            try? FileManager.default.createDirectory(at: playlistDirURL, withIntermediateDirectories: true)
            let playlistPath = playlistDirURL.appendingPathComponent(playlistName)

            try normalizedM3U.write(to: playlistPath, atomically: true, encoding: .utf8)

            // Persist snapshot for iOS dialect (WP3) — enables ingest diff
            if isIOS, let playlistId = playlist.id {
                let snapshotJson: [[String: String?]] = snapshotEntries.map {
                    ["uuid": $0.uuid, "path": $0.path]
                }
                let data = try JSONSerialization.data(withJSONObject: snapshotJson)
                let json = String(data: data, encoding: .utf8) ?? "[]"
                try await syncRepository.databaseWriter.write { db in
                    try db.execute(
                        sql: "DELETE FROM playlist_sync_snapshots WHERE profile_id = ? AND playlist_id = ?",
                        arguments: [profileId, playlistId]
                    )
                    try db.execute(
                        sql: """
                            INSERT INTO playlist_sync_snapshots (profile_id, playlist_id, playlist_uuid, snapshot_json, written_at)
                            VALUES (?, ?, ?, ?, datetime('now'))
                            """,
                        arguments: [profileId, playlistId, playlist.mlmUuid, json]
                    )
                }
            }
        }
    }

    // MARK: - iOS UUID Ensuring

    /// Ensure every playlist and its tracks have stable `mlm_uuid` values, persisting any newly generated ones.
    private func ensureMlmUuids(playlists: [Playlist]) async throws {
        var updatedPlaylists: [Playlist] = []
        var updatedTracks: [Track] = []
        let playlistRepo = PlaylistRepository(database: syncRepository.databaseWriter)

        for var playlist in playlists {
            guard let playlistId = playlist.id else { continue }
            let tracks = try await playlistRepo.fetchTracks(playlistId: playlistId)

            if playlist.ensureMlmUuid() {
                updatedPlaylists.append(playlist)
            }
            for var track in tracks {
                if track.ensureMlmUuid() {
                    updatedTracks.append(track)
                }
            }
        }

        // Persist all newly assigned UUIDs in a single write transaction
        if !updatedPlaylists.isEmpty || !updatedTracks.isEmpty {
            try await syncRepository.databaseWriter.write { db in
                for var pl in updatedPlaylists {
                    try pl.update(db)
                }
                for var tr in updatedTracks {
                    tr.searchText = DatabaseManager.foldedSearchText(tr.rawSearchText)
                    try tr.update(db)
                }
            }
        }
    }

    // MARK: - iOS Manifest

    /// Write `mlm-library.json` into the profile output root (iOS dialect, spec §3).
    ///
    /// Collects all profile tracks whose destination file physically exists,
    /// plus all profile playlists with their generated filenames.
    func generateManifest(profileId: Int64, profile: SyncProfile, libraryRoot: String) async throws {
        let profileDir = URL(fileURLWithPath: profile.outputFolder)
        let musicRoot = URL(fileURLWithPath: Self.musicRootFolder(for: profile))

        // Resolve profile track set (manual + rules)
        let rules = try await syncRepository.fetchProfileRules(profileId: profileId)
        let trackIds = try await trackRepository.fetchTrackIdsForSyncProfile(profileId: profileId, rules: rules)
        let allTracks = try await trackRepository.fetchTracks(ids: trackIds)

        // Ensure UUIDs for manifest tracks
        var tracksNeedingPersist: [Track] = []
        var manifestTracks: [ManifestTrack] = []
        for var track in allTracks {
            let destPath = TranscodeCache.buildProfilePath(
                track: track,
                libraryRoot: libraryRoot,
                profileOutputFolder: Self.musicRootFolder(for: profile),
                transcodeMode: profile.transcodeModeEnum
            )
            let fileURL = URL(fileURLWithPath: destPath.path)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            if track.ensureMlmUuid() {
                tracksNeedingPersist.append(track)
            }
            guard let uuid = track.mlmUuid else { continue }

            // Manifest `path` is relative to the music root (spec §3):
            // for .ios profiles this strips the Music/ prefix; for rockbox/doppi
            // musicRoot == profileDir so the behaviour is unchanged.
            let relativePath = destPath.path.replacingOccurrences(of: musicRoot.path + "/", with: "")
            manifestTracks.append(ManifestTrack(
                uuid: uuid,
                title: track.title,
                artist: track.artist,
                albumArtist: track.albumArtist,
                album: track.album,
                duration: track.duration ?? 0,
                path: relativePath,
                energyBucket: track.energyBucket,
                lufsI: track.lufsI
            ))
        }

        // Persist any newly generated track UUIDs
        if !tracksNeedingPersist.isEmpty {
            try await syncRepository.databaseWriter.write { db in
                for var tr in tracksNeedingPersist {
                    tr.searchText = DatabaseManager.foldedSearchText(tr.rawSearchText)
                    try tr.update(db)
                }
            }
        }

        // Resolve playlists
        let playlists = try await syncRepository.fetchProfilePlaylists(profileId: profileId)
        if playlists.contains(where: { $0.mlmUuid == nil }) {
            try await ensureMlmUuids(playlists: playlists)
        }
        // Re-fetch after potential UUID persistence
        let freshPlaylists = try await syncRepository.fetchProfilePlaylists(profileId: profileId)
        let manifestPlaylists: [ManifestPlaylist] = freshPlaylists.map { pl in
            let extStr = ".m3u8"
            let filename = PathSanitizer.sanitizeComponent(pl.name) + extStr
            return ManifestPlaylist(
                uuid: pl.mlmUuid ?? "",
                name: pl.name,
                file: filename
            )
        }

        let manifest = LibraryManifest(
            schema: 1,
            profile: profile.name,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            tracks: manifestTracks,
            playlists: manifestPlaylists
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let manifestURL = profileDir.appendingPathComponent("mlm-library.json")
        try data.write(to: manifestURL)
    }

    // MARK: - Helpers

    private func estimateFileSize(track: Track, profile: SyncProfile, libraryRoot: String) -> Int64 {
        let duration = Double(track.duration ?? 240)

        switch profile.transcodeModeEnum {
        case .keepOriginals:
            let sourcePaths = [track.organizedPath, track.originalPath].compactMap { $0 }
            for sourcePath in sourcePaths {
                if let url = TranscodeCache.resolveSourceURL(sourcePath: sourcePath, libraryRoot: libraryRoot),
                   let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attributes[.size] as? NSNumber {
                    return size.int64Value
                }
            }

            let bitrate = Double(track.bitrate ?? 248)
            return Int64((bitrate * 1_000 / 8) * duration)
        case .aac248:
            return Int64((248_000 / 8) * duration)
        case .aac320:
            return Int64((320_000 / 8) * duration)
        }
    }

    private static func userFacingFailureReason(_ error: Error) -> String {
        let message = error.localizedDescription.lowercased()
        if message.contains("space") || message.contains("disk full") {
            return "Destination is full"
        }
        if message.contains("not found") || message.contains("no such file") {
            return "Source file is missing"
        }
        if message.contains("permission") || message.contains("access") {
            return "The destination is not writable"
        }
        return "Could not sync this track"
    }

    // MARK: - MLM UUID tag embedding

    /// Re-mux `sourceURL` into `scratchOutput`, stamping the MLM UUID tag (and faststart).
    ///
    /// Owns the extension switch, ffmpeg-missing warning, existing-comment read,
    /// arg construction, ProcessRunner invocation, and scratch-output cleanup on
    /// failure. Both `embedMlmUuid(track:destinationURL:)` and
    /// `TranscodeCache.embedMlmUuidIntoCacheIfNeeded` funnel through this helper
    /// so the embed logic lives in exactly one place.
    ///
    /// Returns true when ffmpeg succeeded and `scratchOutput` is readable.
    /// On failure `scratchOutput` is removed if it exists.
    static func embedMlmUuid(uuid: String, sourceURL: URL, scratchOutput: URL) async -> Bool {
        let ext = sourceURL.pathExtension.lowercased()

        // Read existing comment before building args (m4a/aac/mp4 preserve user comment)
        let existingComment: String?
        switch ext {
        case "m4a", "aac", "mp4":
            existingComment = await readExistingComment(url: sourceURL)
        default:
            existingComment = nil
        }

        guard let ffmpeg = ProcessRunner.findExecutable("ffmpeg") else {
            AppLogger.shared.warn(
                "embedMlmUuid: ffmpeg not found; skipping tag embed for \(sourceURL.lastPathComponent)",
                source: "Sync"
            )
            return false
        }

        guard let args = embedMlmUuidArguments(
            uuid: uuid,
            inputPath: sourceURL.path,
            outputPath: scratchOutput.path,
            fileExtension: ext,
            existingComment: existingComment
        ) else {
            AppLogger.shared.debug(
                "embedMlmUuid: skipping unsupported format '\(ext)' for \(sourceURL.lastPathComponent)",
                source: "Sync"
            )
            return false
        }

        do {
            let result = try await ProcessRunner.run(ffmpeg, arguments: args)
            if result.isSuccess {
                guard FileManager.default.fileExists(atPath: scratchOutput.path) else {
                    AppLogger.shared.warn(
                        "embedMlmUuid: ffmpeg reported success but output missing for \(sourceURL.lastPathComponent)",
                        source: "Sync"
                    )
                    return false
                }
                return true
            } else {
                AppLogger.shared.warn(
                    "embedMlmUuid: ffmpeg failed (exit \(result.exitCode)) for \(sourceURL.lastPathComponent): \(result.stderr.prefix(200))",
                    source: "Sync"
                )
                try? FileManager.default.removeItem(at: scratchOutput)
                return false
            }
        } catch {
            AppLogger.shared.warn(
                "embedMlmUuid: error embedding UUID for \(sourceURL.lastPathComponent): \(error.localizedDescription)",
                source: "Sync"
            )
            try? FileManager.default.removeItem(at: scratchOutput)
            return false
        }
    }

    /// Embed the track's `mlm_uuid` into the destination file's metadata.
    ///
    /// - mp3 → ID3 TXXX frame with description `MLM_UUID`
    /// - m4a/aac/mp4 → `comment` field prefixed with `MLM_UUID:<uuid>`;
    ///   any pre-existing user comment is preserved after a `|||` separator.
    ///
    /// Embedding failure NEVER fails the sync — errors are logged and ignored.
    /// Uses ffmpeg's `-metadata` flag for formats it supports cleanly.
    ///
    /// Two-phase swap: ffmpeg writes to local scratch (avoids faststart second
    /// pass on the slow device volume), then scratch is copied to a dot-prefixed
    /// sibling temp on the destination volume, and only then is the destination
    /// removed and the sibling renamed into place. If the sibling copy fails the
    /// original destination is left completely untouched.
    func embedMlmUuid(track: Track, destinationURL: URL) async {
        guard let uuid = track.mlmUuid, !uuid.isEmpty else { return }
        if await UuidTagIO.readMlmUuid(from: destinationURL) == uuid { return }

        let ext = destinationURL.pathExtension.lowercased()

        // Local scratch temp — ffmpeg's faststart second pass rewrites the entire
        // output, so doing it locally avoids a full device-volume round-trip.
        let scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(".mlm_embed_\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: scratchURL) }

        guard await Self.embedMlmUuid(uuid: uuid, sourceURL: destinationURL, scratchOutput: scratchURL) else {
            return
        }

        // Copy scratch → sibling temp on the destination volume. The sibling
        // must live on the same volume so the final rename is same-volume
        // (effectively free) and the destination is never removed until the
        // new bytes are safely there.
        let destDir = destinationURL.deletingLastPathComponent()
        let destName = destinationURL.lastPathComponent
        let siblingURL = destDir.appendingPathComponent(".\(destName).mlm_swap_\(UUID().uuidString)")

        do {
            try FileManager.default.copyItem(at: scratchURL, to: siblingURL)
        } catch {
            AppLogger.shared.warn(
                "embedMlmUuid: copy to destination volume failed for \(destName): \(error.localizedDescription)",
                source: "Sync"
            )
            try? FileManager.default.removeItem(at: siblingURL)
            return
        }

        // Bytes are on the destination volume — safe to remove+rename.
        do {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: siblingURL, to: destinationURL)
            AppLogger.shared.debug(
                "embedMlmUuid: embedded UUID into \(destName)",
                source: "Sync"
            )
        } catch {
            AppLogger.shared.error(
                "embedMlmUuid: rename to destination failed for \(destName): \(error.localizedDescription) — attempting restore",
                source: "Sync"
            )
            // Try to restore by moving the sibling back into place.
            do {
                try FileManager.default.moveItem(at: siblingURL, to: destinationURL)
            } catch {
                AppLogger.shared.error(
                    "embedMlmUuid: restore also failed for \(destName): \(error.localizedDescription) — sibling temp left at \(siblingURL.lastPathComponent)",
                    source: "Sync"
                )
            }
        }
    }

    /// Read the existing `comment` tag from an audio file via ffprobe.
    /// Returns nil on any failure (missing ffprobe, unreadable file, no comment).
    static func readExistingComment(url: URL) async -> String? {
        guard let ffprobe = ProcessRunner.findExecutable("ffprobe") else { return nil }
        let args = [
            "-v", "quiet",
            "-show_entries", "format_tags=comment",
            "-of", "csv=p=0",
            url.path,
        ]
        do {
            let result = try await ProcessRunner.run(ffprobe, arguments: args)
            guard result.isSuccess else { return nil }
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    /// Build the comment-field value that embeds `uuid` while preserving any
    /// pre-existing user comment.
    ///
    /// - No existing comment → `MLM_UUID:<uuid>`
    /// - Existing comment already starts with `MLM_UUID:` → replace the uuid
    ///   portion (idempotent re-embed), keep anything after `|||`.
    /// - Existing comment without our prefix → `MLM_UUID:<uuid>|||<existing>`
    static func buildMlmComment(uuid: String, existingComment: String?) -> String {
        guard let existing = existingComment, !existing.isEmpty else {
            return "MLM_UUID:\(uuid)"
        }
        if existing.hasPrefix("MLM_UUID:") {
            // Idempotent: replace the uuid portion, preserve anything after |||
            if let separatorRange = existing.range(of: "|||") {
                return "MLM_UUID:\(uuid)\(existing[separatorRange.lowerBound...])"
            }
            return "MLM_UUID:\(uuid)"
        }
        return "MLM_UUID:\(uuid)|||\(existing)"
    }

    /// Parse an MLM UUID out of a comment-field value written by `buildMlmComment`.
    /// Returns nil if the comment does not carry our prefix.
    static func parseMlmUuid(fromComment comment: String) -> String? {
        guard comment.hasPrefix("MLM_UUID:") else { return nil }
        let afterPrefix = comment.dropFirst("MLM_UUID:".count)
        if let separatorIndex = afterPrefix.range(of: "|||")?.lowerBound {
            let uuid = String(afterPrefix[..<separatorIndex])
            return uuid.isEmpty ? nil : uuid
        }
        let uuid = String(afterPrefix)
        return uuid.isEmpty ? nil : uuid
    }

    /// Build the ffmpeg arguments that would embed `mlm_uuid` into a file.
    /// Exposed for testing the command construction without running ffmpeg.
    ///
    /// For m4a/aac/mp4, `existingComment` controls the comment-field value
    /// (see `buildMlmComment`). Pass nil/empty for the simple case.
    static func embedMlmUuidArguments(
        uuid: String,
        inputPath: String,
        outputPath: String,
        fileExtension: String,
        existingComment: String? = nil
    ) -> [String]? {
        let metadataKey: String
        let metadataValue: String
        switch fileExtension.lowercased() {
        case "mp3":
            metadataKey = "TXXX:MLM_UUID"
            metadataValue = uuid
        case "m4a", "aac", "mp4":
            metadataKey = "comment"
            metadataValue = buildMlmComment(uuid: uuid, existingComment: existingComment)
        default:
            return nil
        }
        return [
            "-y",
            "-i", inputPath,
            "-map", "0:a",
            "-map", "0:v?",
            "-c", "copy",
            "-metadata", "\(metadataKey)=\(metadataValue)",
            // Keep moov before mdat so players can start playback before the
            // whole file is read. Harmless no-op on mp3/ADTS aac.
            "-movflags", "+faststart",
            outputPath,
        ]
    }

    // MARK: - Playlist Metadata Memo

    struct PlaylistTrackMemoEntry: Equatable {
        let exists: Bool
        let artist: String
        let title: String
        let albumArtist: String?
    }

    static func memoizedMetadata<K: Hashable>(
        key: K,
        in cache: inout [K: PlaylistTrackMemoEntry],
        loader: () async throws -> PlaylistTrackMemoEntry
    ) async rethrows -> PlaylistTrackMemoEntry {
        if let cached = cache[key] {
            return cached
        }
        let value = try await loader()
        cache[key] = value
        return value
    }
}
