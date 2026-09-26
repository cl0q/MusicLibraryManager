import Foundation
import Testing
import GRDB
@testable import MLM

@Suite("FolderSelectionRegressionTests", .serialized)
@MainActor
struct FolderSelectionRegressionTests {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeViewModel() throws -> (DatabaseQueue, ConfigRepository, FolderViewModel) {
        let database = try DatabaseManager.inMemory()
        let configRepository = ConfigRepository(database: database)
        let trackRepository = TrackRepository(database: database)
        return (
            database,
            configRepository,
            FolderViewModel(
                trackRepository: trackRepository,
                configRepository: configRepository
            )
        )
    }

    @Test
    func restoredSelectionIsDiscardedWhenLibraryRootChanges() async throws {
        let defaults = UserDefaults.standard
        let keys = [
            FolderViewModel.lastSelectionKey,
            FolderViewModel.lastSelectionRootKey,
            FolderViewModel.lastSelectionRelativePathKey
        ]
        keys.forEach(defaults.removeObject(forKey:))
        defer { keys.forEach(defaults.removeObject(forKey:)) }

        let originalRoot = Self.repositoryRoot.appendingPathComponent("MLM").standardizedFileURL
        let replacementRoot = Self.repositoryRoot.appendingPathComponent("MLMTests").standardizedFileURL
        let (database, configRepository, viewModel) = try makeViewModel()
        try await configRepository.setLibraryRoot(originalRoot.path)
        await viewModel.loadRootFolders()
        viewModel.selectedFolderPath = originalRoot.appendingPathComponent("Views").path
        viewModel.persistLastSelection()

        #expect(
            defaults.string(forKey: FolderViewModel.lastSelectionRootKey) == originalRoot.path
        )
        #expect(
            defaults.string(forKey: FolderViewModel.lastSelectionRelativePathKey) == "Views"
        )

        try await configRepository.setLibraryRoot(replacementRoot.path)
        let reloadedViewModel = FolderViewModel(
            trackRepository: TrackRepository(database: database),
            configRepository: configRepository
        )
        await reloadedViewModel.loadRootFolders()

        #expect(reloadedViewModel.selectedFolderPath == nil)
        #expect(defaults.string(forKey: FolderViewModel.lastSelectionRootKey) == nil)
        #expect(defaults.string(forKey: FolderViewModel.lastSelectionRelativePathKey) == nil)
    }

    @Test
    func restoreRejectsRelativePathThatEscapesLibraryRoot() async throws {
        let defaults = UserDefaults.standard
        let keys = [
            FolderViewModel.lastSelectionKey,
            FolderViewModel.lastSelectionRootKey,
            FolderViewModel.lastSelectionRelativePathKey
        ]
        keys.forEach(defaults.removeObject(forKey:))
        defer { keys.forEach(defaults.removeObject(forKey:)) }

        let root = Self.repositoryRoot.appendingPathComponent("MLM").standardizedFileURL
        defaults.set(root.path, forKey: FolderViewModel.lastSelectionRootKey)
        defaults.set("../MLMTests", forKey: FolderViewModel.lastSelectionRelativePathKey)

        let (_, configRepository, viewModel) = try makeViewModel()
        try await configRepository.setLibraryRoot(root.path)
        await viewModel.loadRootFolders()

        #expect(viewModel.selectedFolderPath == nil)
        #expect(defaults.string(forKey: FolderViewModel.lastSelectionRootKey) == nil)
        #expect(defaults.string(forKey: FolderViewModel.lastSelectionRelativePathKey) == nil)
    }
}
