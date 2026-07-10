import SwiftUI

/// ViewModel for sync profile management and execution.
@Observable
final class SyncViewModel {
    // MARK: - State

    private(set) var profiles: [SyncProfile] = []
    var selectedProfile: SyncProfile?
    private(set) var preview: SyncService.SyncPreview?
    private(set) var isLoading = false
    private(set) var isSyncing = false
    private(set) var lastResult: SyncService.SyncResult?
    private(set) var errorMessage: String?

    // Loaded content for the selected profile (used by SyncContentSections)
    private(set) var profilePlaylists: [Playlist] = []
    private(set) var profileTracks: [Track] = []

    // MARK: - Dependencies

    private let syncRepository: SyncRepository
    let syncService: SyncService

    init(syncRepository: SyncRepository, syncService: SyncService) {
        self.syncRepository = syncRepository
        self.syncService = syncService
    }

    // MARK: - CRUD

    func loadProfiles() async {
        isLoading = true
        let start = Date()
        do {
            profiles = try await syncRepository.fetchAll()
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

    func clearError() {
        errorMessage = nil
    }

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
        } catch {
            let errMsg = error.localizedDescription
            if errMsg.contains("UNIQUE constraint failed") {
                errorMessage = "Ein Sync-Profil mit diesem Namen existiert bereits."
            } else {
                errorMessage = errMsg
            }
        }
    }

    func deleteProfile(_ profile: SyncProfile) async {
        guard let id = profile.id else { return }
        do {
            try await syncRepository.delete(id: id)
            profiles.removeAll { $0.id == id }
            if selectedProfile?.id == id {
                selectedProfile = nil
                preview = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectProfile(_ profile: SyncProfile) async {
        selectedProfile = profile
        await loadPreview(for: profile)
    }

    // MARK: - Preview

    func loadPreview(for profile: SyncProfile) async {
        guard let id = profile.id else { return }
        isLoading = true
        do {
            preview = try await syncService.previewSync(profileId: id)
            await loadProfileContent(profileId: id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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

    func executeSync() async {
        guard let profile = selectedProfile, let id = profile.id else { return }
        isSyncing = true
        errorMessage = nil

        do {
            let result = try await syncService.executeSync(profileId: id)
            lastResult = result
            AppLogger.shared.log(
                "Sync complete: \(result.syncedCount) synced, \(result.failedCount) failed",
                source: "Sync"
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isSyncing = false
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

    // MARK: - Cancellation (D-14)

    func cancelSync() {
        syncService.cancelSync()
    }

    // MARK: - Single-Track Retry (D-13)

    @MainActor
    func retryFailedTrack(_ trackId: Int64) async {
        guard let profile = selectedProfile, let profileId = profile.id else { return }
        do {
            let result = try await syncService.executeSyncSingleTrack(profileId: profileId, trackId: trackId)
            if result.syncedCount > 0 {
                await loadProfileContent(profileId: profileId)
            }
            NotificationCenter.default.post(
                name: .syncProfileDidChange, object: nil, userInfo: ["profileId": profileId]
            )
        } catch {
            errorMessage = "Retry failed: \(error.localizedDescription)"
        }
    }
}
