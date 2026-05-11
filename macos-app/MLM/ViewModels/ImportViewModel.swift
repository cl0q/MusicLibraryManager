import Foundation
import GRDB

/// ViewModel for managing audio file imports.
///
/// Tracks import progress, handles library root selection,
/// and coordinates between `ImportService` and the UI.
@Observable
final class ImportViewModel {
    // MARK: - Published State

    /// Whether an import is currently in progress.
    private(set) var isImporting = false

    /// Current import progress (nil when not importing).
    private(set) var progress: ImportService.ImportProgress?

    /// Result of the last completed import (nil if none).
    private(set) var lastResult: ImportService.ImportResult?

    /// Error message from the last failed operation.
    private(set) var errorMessage: String?

    /// The configured library root path (from app_config).
    private(set) var libraryRoot: String?

    /// Whether the library root has been configured.
    var hasLibraryRoot: Bool { libraryRoot != nil }

    // MARK: - Dependencies

    private let importService: ImportService
    private let configRepository: ConfigRepository

    // MARK: - Init

    init(importService: ImportService, configRepository: ConfigRepository) {
        self.importService = importService
        self.configRepository = configRepository
    }

    // MARK: - Library Root

    /// Load the library root from the database.
    @MainActor
    func loadLibraryRoot() async {
        do {
            libraryRoot = try await configRepository.getLibraryRoot()
        } catch {
            errorMessage = "Failed to load library root: \(error.localizedDescription)"
        }
    }

    /// Set and persist the library root.
    ///
    /// - Parameter path: Absolute path to the library root directory
    @MainActor
    func setLibraryRoot(_ path: String) async {
        do {
            try await configRepository.setLibraryRoot(path)
            libraryRoot = path
            errorMessage = nil
            // Notify dependent services (e.g. DownloadViewModel) so they can
            // reconfigure for the new root without an app restart.
            NotificationCenter.default.post(
                name: .libraryRootDidChange,
                object: nil,
                userInfo: ["path": path]
            )
        } catch {
            errorMessage = "Failed to save library root: \(error.localizedDescription)"
        }
    }

    // MARK: - Import

    /// Import all audio files from the library root directory.
    ///
    /// Scans recursively, extracts metadata, and saves to database.
    /// Progress is reported via the `progress` property.
    /// Posts `.libraryDidImport` notification on success.
    @MainActor
    func importLibrary() async {
        guard let root = libraryRoot else {
            errorMessage = "No library root configured"
            return
        }

        let rootURL = URL(fileURLWithPath: root)

        guard FileManager.default.fileExists(atPath: root) else {
            errorMessage = "Library root does not exist: \(root)"
            return
        }

        isImporting = true
        errorMessage = nil
        lastResult = nil
        progress = nil

        do {
            let result = try await importService.importDirectory(rootURL) { [weak self] progress in
                Task { @MainActor in
                    self?.progress = progress
                }
            }

            lastResult = result
            progress = nil

            if result.failed > 0 {
                errorMessage = "\(result.failed) file(s) failed to import"
            }

            // Notify other views that library data has changed
            NotificationCenter.default.post(
                name: .libraryDidImport,
                object: nil,
                userInfo: [
                    "succeeded": result.succeeded,
                    "skipped": result.skipped
                ]
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isImporting = false
    }

    /// Import from a specific directory (for manual folder selection).
    ///
    /// - Parameter directory: Directory to scan and import from
    /// Posts `.libraryDidImport` notification on success.
    @MainActor
    func importFromDirectory(_ directory: URL) async {
        isImporting = true
        errorMessage = nil
        lastResult = nil
        progress = nil

        do {
            let result = try await importService.importDirectory(directory) { [weak self] progress in
                Task { @MainActor in
                    self?.progress = progress
                }
            }

            lastResult = result
            progress = nil

            if result.failed > 0 {
                errorMessage = "\(result.failed) file(s) failed to import"
            }

            // Notify other views that library data has changed
            NotificationCenter.default.post(
                name: .libraryDidImport,
                object: nil,
                userInfo: [
                    "succeeded": result.succeeded,
                    "skipped": result.skipped
                ]
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isImporting = false
    }

    /// Clear the last result and error state.
    @MainActor
    func clearResult() {
        lastResult = nil
        errorMessage = nil
    }
}
