import SwiftUI

/// ViewModel for sync profile management and execution.
@Observable
final class SyncViewModel {
    // MARK: - State

    private(set) var profiles: [SyncProfile] = []
    private(set) var profileLastSynced: [Int64: Date] = [:]
    var selectedProfile: SyncProfile?
    private(set) var preview: SyncService.SyncPreview?
    private(set) var isLoading = false
    private(set) var isPreviewUpdating = false
    private(set) var isPreviewStale = true
    private(set) var previewProcessed = 0
    private(set) var previewTotal = 0
    private(set) var previewComputedAt: Date?
    private(set) var isSyncing = false
    private(set) var syncSettingsApplyNextRun = false
    private(set) var lastResult: SyncService.SyncResult?
    private(set) var errorMessage: String?

    // Loaded content for the selected profile (used by SyncContentSections)
    private(set) var profilePlaylists: [Playlist] = []
    private(set) var profileTracks: [Track] = []

    // MARK: - Dependencies

    private let syncRepository: SyncRepository
    let syncService: SyncService
    private var previewTask: Task<Void, Never>?
    private var previewRequest = UUID()
    private static let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    private static let relativeTimeFormatter = RelativeDateTimeFormatter()

    init(syncRepository: SyncRepository, syncService: SyncService) {
        self.syncRepository = syncRepository
        self.syncService = syncService
    }

    // MARK: - CRUD

    @MainActor
    func loadProfiles() async {
        isLoading = true
        let start = Date()
        do {
            profiles = try await syncRepository.fetchAll()
            let timestamps = try await syncRepository.fetchLastSyncTimestamps()
            profileLastSynced = Dictionary(uniqueKeysWithValues: timestamps.compactMap { id, timestamp in
                Self.sqliteDateFormatter.date(from: timestamp).map { (id, $0) }
            })
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            AppLogger.shared.info(
                "sync profiles loaded: \(profiles.count) in \(ms)ms",
                source: "perf"
            )
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.shared.error("sync profiles load failed: \(error)", source: "sync")
        }
        isLoading = false
    }

    @MainActor
    func clearError() {
        errorMessage = nil
    }

    @MainActor
    func createProfile(
        name: String,
        outputFolder: String,
        generateM3U8: Bool = false,
        transcodeMode: String = "keep_originals",
        fat32SafePaths: Bool = true,
        cleanupRemovedFiles: Bool = true
    ) async {
        errorMessage = nil
        do {
            let profile = try await syncRepository.create(name: name, outputFolder: outputFolder)
            // Apply toggle settings immediately after creation
            if let id = profile.id {
                try await syncRepository.updateSettings(
                    profileId: id,
                    generateM3U8: generateM3U8,
                    transcodeMode: transcodeMode,
                    fat32SafePaths: fat32SafePaths,
                    cleanupRemovedFiles: cleanupRemovedFiles
                )
            }
            await loadProfiles()
            selectedProfile = profiles.first { $0.id == profile.id }
            if let selectedProfile {
                schedulePreviewRefresh(for: selectedProfile, debounced: false)
            }
        } catch {
            let errMsg = error.localizedDescription
            if errMsg.contains("UNIQUE constraint failed") {
                errorMessage = "A sync profile with this name already exists."
            } else {
                errorMessage = errMsg
            }
        }
    }

    @MainActor
    func deleteProfile(_ profile: SyncProfile) async {
        guard let id = profile.id else { return }
        do {
            try await syncRepository.delete(id: id)
            profiles.removeAll { $0.id == id }
            if selectedProfile?.id == id {
                selectedProfile = nil
                preview = nil
                previewTask?.cancel()
            }
            syncService.invalidatePreview(profileId: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func selectProfile(_ profile: SyncProfile) async {
        selectedProfile = profile
        await loadPreview(for: profile)
    }

    @MainActor
    func renameProfile(_ profile: SyncProfile, name: String) async {
        guard let id = profile.id else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        do {
            try await syncRepository.updateSettings(profileId: id, name: trimmedName)
            await loadProfiles()
            if selectedProfile?.id == id {
                selectedProfile = profiles.first { $0.id == id }
            }
        } catch {
            errorMessage = "Could not rename sync profile."
            AppLogger.shared.error("sync profile rename failed: \(error)", source: "Sync")
        }
    }

    @MainActor
    func duplicateProfile(_ profile: SyncProfile) async {
        guard let id = profile.id else { return }
        do {
            let copy = try await syncRepository.duplicate(id: id)
            await loadProfiles()
            selectedProfile = profiles.first { $0.id == copy.id }
            if let selectedProfile {
                schedulePreviewRefresh(for: selectedProfile, debounced: false)
            }
        } catch {
            errorMessage = "Could not duplicate sync profile."
            AppLogger.shared.error("sync profile duplicate failed: \(error)", source: "Sync")
        }
    }

    @MainActor
    func profileStatus(for profile: SyncProfile) -> String {
        guard let id = profile.id else { return "No sync yet" }
        if selectedProfile?.id == id, isSyncing {
            return "Syncing \(syncProcessed)/\(syncTotal)"
        }
        if !FileManager.default.fileExists(atPath: profile.outputFolder) {
            return "Device not connected"
        }
        if selectedProfile?.id == id, let preview, preview.isDeviceConnected {
            let pending = preview.filesToAdd.count + preview.filesToRemove.count
            if pending > 0 {
                return "\(pending) \(pending == 1 ? "track" : "tracks") pending"
            }
        }
        if let lastSynced = profileLastSynced[id] {
            return "Synced \(Self.relativeTimeFormatter.localizedString(for: lastSynced, relativeTo: Date()))"
        }
        return "No sync yet"
    }

    // MARK: - Preview

    @MainActor
    func loadPreview(for profile: SyncProfile) async {
        await requestPreview(for: profile, forceRefresh: false)
    }

    @MainActor
    func refreshPreviewNow(for profile: SyncProfile) async {
        await requestPreview(for: profile, forceRefresh: true)
    }

    @MainActor
    private func requestPreview(for profile: SyncProfile, forceRefresh: Bool) async {
        previewTask?.cancel()
        let request = UUID()
        previewRequest = request
        profilePlaylists = []
        profileTracks = []
        presentCachedPreview(for: profile)
        if let profileId = profile.id {
            Task { await self.loadProfileContent(profileId: profileId) }
        }
        await refreshPreview(for: profile, request: request, forceRefresh: forceRefresh)
    }

    @MainActor
    func schedulePreviewRefresh(for profile: SyncProfile, debounced: Bool = true) {
        previewTask?.cancel()
        let request = UUID()
        previewRequest = request
        presentCachedPreview(for: profile)
        isPreviewStale = true
        isPreviewUpdating = true

        previewTask = Task { [weak self] in
            guard let self else { return }
            if debounced {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self.refreshPreview(for: profile, request: request, forceRefresh: false)
        }
    }

    @MainActor
    func cancelPreviewRefresh() {
        previewTask?.cancel()
        previewTask = nil
        previewRequest = UUID()
        isPreviewUpdating = false
        isPreviewStale = true
        PerformanceQueueService.shared.setExternalSyncPreviewActive(false)
    }

    @MainActor
    func deviceAvailabilityDidChange(for profile: SyncProfile) {
        guard let profileId = profile.id else { return }
        let cachedAvailability = syncService.cachedPreview(profileId: profileId)?.deviceWasConnected
        let currentAvailability = FileManager.default.fileExists(atPath: profile.outputFolder)
        guard cachedAvailability != currentAvailability else { return }
        syncService.invalidatePreview(profileId: profileId)
        schedulePreviewRefresh(for: profile, debounced: false)
    }

    @MainActor
    private func presentCachedPreview(for profile: SyncProfile) {
        guard let profileId = profile.id,
              let cached = syncService.cachedPreview(profileId: profileId),
              cached.deviceWasConnected == FileManager.default.fileExists(atPath: profile.outputFolder)
        else {
            return
        }

        preview = cached.preview
        previewComputedAt = cached.computedAt
        previewProcessed = 0
        previewTotal = 0
    }

    @MainActor
    private func refreshPreview(
        for profile: SyncProfile,
        request: UUID,
        forceRefresh: Bool
    ) async {
        guard let id = profile.id else { return }
        guard selectedProfile?.id == id || selectedProfile == nil else { return }
        isPreviewUpdating = true
        isPreviewStale = preview != nil
        previewProcessed = 0
        previewTotal = 0
        PerformanceQueueService.shared.setExternalSyncPreviewActive(true)
        defer {
            if previewRequest == request {
                PerformanceQueueService.shared.setExternalSyncPreviewActive(false)
            }
        }

        do {
            let freshPreview = try await syncService.previewSync(
                profileId: id,
                forceRefresh: forceRefresh
            ) { [weak self] processed, total in
                Task { @MainActor in
                    guard let self, self.previewRequest == request else { return }
                    self.previewProcessed = processed
                    self.previewTotal = total
                }
            }
            guard previewRequest == request, !Task.isCancelled else { return }
            preview = freshPreview
            previewComputedAt = syncService.cachedPreview(profileId: id)?.computedAt
            previewProcessed = previewTotal
            isPreviewStale = false
        } catch is CancellationError {
            // The next preview request owns the UI state.
        } catch {
            guard previewRequest == request else { return }
            errorMessage = "Could not update the sync preview. Try Refresh."
            AppLogger.shared.error("sync preview failed: \(error)", source: "Sync")
        }

        guard previewRequest == request else { return }
        isPreviewUpdating = false
    }

    // MARK: - Profile Content (D-08)

    @MainActor
    func loadProfileContent(profileId: Int64) async {
        do {
            profilePlaylists = try await syncRepository.fetchProfilePlaylists(profileId: profileId)
            profileTracks = try await syncRepository.fetchProfileTracks(profileId: profileId)
        } catch {
            AppLogger.shared.error("loadProfileContent failed: \(error)", source: "sync")
        }
    }

    // MARK: - Sync

    @MainActor
    func executeSync() async {
        guard let profile = selectedProfile, let id = profile.id else { return }
        isSyncing = true
        syncSettingsApplyNextRun = false
        errorMessage = nil

        do {
            let result = try await syncService.executeSync(profileId: id)
            lastResult = result
            AppLogger.shared.log(
                "Sync complete: \(result.syncedCount) synced, \(result.failedCount) failed",
                source: "Sync"
            )
            syncService.invalidatePreview(profileId: id)
            schedulePreviewRefresh(for: profile, debounced: false)
        } catch {
            errorMessage = error.localizedDescription
        }

        isSyncing = false
        syncSettingsApplyNextRun = false
    }

    // MARK: - Content Mutations (D-08)

    @MainActor
    func addPlaylists(_ playlistIds: [Int64]) async {
        guard let profileId = selectedProfile?.id else { return }
        do {
            for id in playlistIds {
                try await syncRepository.addPlaylist(profileId: profileId, playlistId: id)
            }
            await loadProfileContent(profileId: profileId)
            invalidateAndSchedulePreview(profileId: profileId)
            NotificationCenter.default.post(
                name: .syncProfileDidChange, object: nil, userInfo: ["profileId": profileId]
            )
        } catch {
            errorMessage = "Failed to add playlists: \(error.localizedDescription)"
        }
    }

    @MainActor
    func addTracks(_ trackIds: [Int64]) async {
        guard let profileId = selectedProfile?.id else { return }
        do {
            for id in trackIds {
                try await syncRepository.addTrack(profileId: profileId, trackId: id)
            }
            await loadProfileContent(profileId: profileId)
            invalidateAndSchedulePreview(profileId: profileId)
            NotificationCenter.default.post(
                name: .syncProfileDidChange, object: nil, userInfo: ["profileId": profileId]
            )
        } catch {
            errorMessage = "Failed to add tracks: \(error.localizedDescription)"
        }
    }

    @MainActor
    func removePlaylists(_ playlistIds: [Int64]) async {
        guard let profileId = selectedProfile?.id else { return }
        do {
            for id in playlistIds {
                try await syncRepository.removePlaylist(profileId: profileId, playlistId: id)
            }
            await loadProfileContent(profileId: profileId)
            invalidateAndSchedulePreview(profileId: profileId)
            NotificationCenter.default.post(
                name: .syncProfileDidChange, object: nil, userInfo: ["profileId": profileId]
            )
        } catch {
            errorMessage = "Failed to remove playlists: \(error.localizedDescription)"
        }
    }

    @MainActor
    func removeTracks(_ trackIds: [Int64]) async {
        guard let profileId = selectedProfile?.id else { return }
        do {
            for id in trackIds {
                try await syncRepository.removeTrack(profileId: profileId, trackId: id)
            }
            await loadProfileContent(profileId: profileId)
            invalidateAndSchedulePreview(profileId: profileId)
            NotificationCenter.default.post(
                name: .syncProfileDidChange, object: nil, userInfo: ["profileId": profileId]
            )
        } catch {
            errorMessage = "Failed to remove tracks: \(error.localizedDescription)"
        }
    }

    @MainActor
    func updateProfileSettings(
        name: String? = nil,
        outputFolder: String? = nil,
        generateM3U8: Bool? = nil,
        transcodeMode: String? = nil,
        fat32SafePaths: Bool? = nil,
        cleanupRemovedFiles: Bool? = nil,
        playlistPathPrefix: String? = nil,
        playlistFormat: String? = nil,
        normalizeLoudness: Bool? = nil
    ) async {
        guard let profileId = selectedProfile?.id else { return }
        do {
            try await syncRepository.updateSettings(
                profileId: profileId,
                name: name,
                outputFolder: outputFolder,
                playlistPathPrefix: playlistPathPrefix,
                generateM3U8: generateM3U8,
                transcodeMode: transcodeMode,
                fat32SafePaths: fat32SafePaths,
                cleanupRemovedFiles: cleanupRemovedFiles,
                playlistFormat: playlistFormat,
                normalizeLoudness: normalizeLoudness
            )
            await loadProfiles()
            // Refresh selectedProfile from the reloaded list to reflect updated fields
            if let updated = profiles.first(where: { $0.id == profileId }) {
                selectedProfile = updated
                if isSyncing {
                    syncSettingsApplyNextRun = true
                }
                invalidateAndSchedulePreview(profileId: profileId, profile: updated)
            }
            NotificationCenter.default.post(
                name: .syncProfileDidChange, object: nil, userInfo: ["profileId": profileId]
            )
        } catch {
            errorMessage = "Failed to update profile settings: \(error.localizedDescription)"
        }
    }

    // MARK: - Progress Forwarding (read-only access for SyncStatusRow in OperationsTab)

    /// Forwarding property — reads SyncService.progress without exposing the service.
    var syncProgress: Double { syncService.progress }

    /// Forwarding property — reads SyncService.currentFile without exposing the service.
    var syncCurrentFile: String { syncService.currentFile }

    /// Forwarding property — reads SyncService.processed without exposing the service.
    var syncProcessed: Int { syncService.processed }

    /// Forwarding property — reads SyncService.total without exposing the service.
    var syncTotal: Int { syncService.total }

    var isSyncPaused: Bool { syncService.isPaused }

    // MARK: - Cancellation (D-14)

    @MainActor
    func cancelSync() {
        syncService.cancelSync()
    }

    @MainActor
    func toggleSyncPause() {
        if syncService.isPaused {
            syncService.resumeSync()
        } else {
            syncService.pauseSync()
        }
    }

    @MainActor
    func setBackgroundProcessing(_ level: SyncTurboLevel) {
        syncService.setSyncTurboLevel(level)
        guard let profile = selectedProfile, let profileId = profile.id else { return }
        invalidateAndSchedulePreview(profileId: profileId, profile: profile)
    }

    // MARK: - Single-Track Retry (D-13)

    @MainActor
    func retryFailedTrack(_ trackId: Int64) async {
        guard let profile = selectedProfile, let profileId = profile.id else { return }
        do {
            let result = try await syncService.executeSyncSingleTrack(profileId: profileId, trackId: trackId)
            if result.syncedCount > 0 {
                if var previous = lastResult {
                    previous.failedTracks.removeAll { $0.trackId == trackId }
                    previous.failedCount = previous.failedTracks.count
                    previous.syncedCount += result.syncedCount
                    lastResult = previous
                }
                removeRetriedTrackFromPreview(trackId)
                syncService.invalidatePreview(profileId: profileId)
            } else if result.failedCount > 0, var previous = lastResult {
                previous.failedTracks.removeAll { $0.trackId == trackId }
                previous.failedTracks.append(contentsOf: result.failedTracks)
                previous.failedCount = previous.failedTracks.count
                lastResult = previous
            }
            NotificationCenter.default.post(
                name: .syncProfileDidChange, object: nil, userInfo: ["profileId": profileId]
            )
        } catch {
            errorMessage = "Retry failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func invalidateAndSchedulePreview(profileId: Int64, profile: SyncProfile? = nil) {
        syncService.invalidatePreview(profileId: profileId)
        guard let selected = profile ?? selectedProfile, selected.id == profileId else { return }
        isPreviewStale = true
        schedulePreviewRefresh(for: selected)
    }

    @MainActor
    private func removeRetriedTrackFromPreview(_ trackId: Int64) {
        guard var currentPreview = preview,
              let index = currentPreview.filesToAdd.firstIndex(where: { $0.trackId == trackId })
        else { return }

        let file = currentPreview.filesToAdd.remove(at: index)
        currentPreview.totalNewSize = max(0, currentPreview.totalNewSize - file.size)
        preview = currentPreview
        previewComputedAt = Date()
        isPreviewStale = false
    }
}
