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

    /// ID of the currently registered Activity operation (if any).
    private(set) var currentOperationID: UUID?

    // MARK: - Dependencies

    private let importService: ImportServicing
    private let configRepository: ConfigRepository
    private let activityViewModel: ActivityViewModel?

    /// Box so the `@Sendable` cancellation closure can reference a Task
    /// that does not yet exist at closure-creation time.
    private final class TaskBox: @unchecked Sendable {
        var task: Task<Void, Never>?
    }

    private var importTaskBox = TaskBox()

    // MARK: - Init

    init(
        importService: ImportServicing,
        configRepository: ConfigRepository,
        activityViewModel: ActivityViewModel? = nil
    ) {
        self.importService = importService
        self.configRepository = configRepository
        self.activityViewModel = activityViewModel
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

        await runImport(
            directory: rootURL,
            title: "Rescan library",
            detail: "Scanning \(URL(fileURLWithPath: root).lastPathComponent)…"
        )
    }

    /// Import from a specific directory (for manual folder selection).
    @MainActor
    func importFromDirectory(_ directory: URL) async {
        await runImport(
            directory: directory,
            title: "Import: \(directory.lastPathComponent)",
            detail: "Scanning \(directory.lastPathComponent)…"
        )
    }

    /// Cancel the in-flight import (used by Settings-side Cancel and Activity panel).
    func cancelImport() {
        importTaskBox.task?.cancel()
    }

    /// Clear the last result and error state.
    @MainActor
    func clearResult() {
        lastResult = nil
        errorMessage = nil
    }

    // MARK: - Private

    @MainActor
    private func runImport(directory: URL, title: String, detail: String) async {
        isImporting = true
        errorMessage = nil
        lastResult = nil
        progress = nil

        let opID = activityViewModel?.startOperation(
            type: .import,
            title: title,
            detail: detail
        )
        currentOperationID = opID

        let box = importTaskBox
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.importService.importDirectory(directory) { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        self.progress = progress
                        if let opID {
                            self.activityViewModel?.updateProgress(
                                id: opID,
                                progress: progress.fraction,
                                detail: progress.currentFile ?? progress.phase
                            )
                        }
                    }
                }

                await MainActor.run {
                    self.lastResult = result
                    self.progress = nil

                    if result.cancelled {
                        if let opID {
                            self.activityViewModel?.cancelOperation(id: opID, detail: "Cancelled")
                        }
                    } else {
                        let summary = "\(result.succeeded) imported, \(result.skipped) skipped"
                        if let opID {
                            self.activityViewModel?.completeOperation(id: opID, detail: summary)
                        }
                        if result.failed > 0 {
                            self.errorMessage = "\(result.failed) file(s) failed to import"
                        }
                        NotificationCenter.default.post(
                            name: .libraryDidImport,
                            object: nil,
                            userInfo: [
                                "succeeded": result.succeeded,
                                "skipped": result.skipped
                            ]
                        )
                        // Files were added or re-read: check the library's files (W2-A).
                        NotificationCenter.default.post(name: .libraryFilesDidChange, object: nil)
                    }
                    self.isImporting = false
                    self.currentOperationID = nil
                }
            } catch {
                await MainActor.run {
                    self.progress = nil
                    if error is CancellationError {
                        if let opID {
                            self.activityViewModel?.cancelOperation(id: opID, detail: "Cancelled")
                        }
                    } else {
                        if let opID {
                            self.activityViewModel?.failOperation(id: opID, error: error.localizedDescription)
                        }
                        self.errorMessage = error.localizedDescription
                    }
                    self.isImporting = false
                    self.currentOperationID = nil
                }
            }
        }
        box.task = task

        if let opID {
            activityViewModel?.registerCancellationToken(id: opID) { [weak self] in
                self?.cancelImport()
            }
        }

        await task.value
    }
}
