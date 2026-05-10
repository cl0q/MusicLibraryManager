import SwiftUI

/// ViewModel for sync profile management and execution.
@Observable
final class SyncViewModel {
    // MARK: - State

    private(set) var profiles: [SyncProfile] = []
    private(set) var selectedProfile: SyncProfile?
    private(set) var preview: SyncService.SyncPreview?
    private(set) var isLoading = false
    private(set) var isSyncing = false
    private(set) var lastResult: SyncService.SyncResult?
    private(set) var errorMessage: String?

    // MARK: - Dependencies

    private let syncRepository: SyncRepository
    private let syncService: SyncService

    init(syncRepository: SyncRepository, syncService: SyncService) {
        self.syncRepository = syncRepository
        self.syncService = syncService
    }

    // MARK: - CRUD

    func loadProfiles() async {
        isLoading = true
        do {
            profiles = try await syncRepository.fetchAll()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func createProfile(name: String, outputFolder: String) async {
        do {
            let profile = try await syncRepository.create(name: name, outputFolder: outputFolder)
            profiles.append(profile)
            selectedProfile = profile
        } catch {
            errorMessage = error.localizedDescription
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
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
}
