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

    /// The words of an import's result in Activity and the status bar (UC-JOB-08):
    /// `35 imported · 2 failed · 3 already in the library`.
    static func activityResult(for result: ImportService.ImportResult) -> ActivityResult {
        let imported = result.cancelled ? result.committed : result.succeeded
        return ActivityResult(counts: [
            ActivityCount(.done, imported, "imported"),
            ActivityCount(.failed, result.failed, "failed"),
            ActivityCount(.skipped, result.skipped, "already in the library"),
        ])
    }

    // MARK: - Dependencies

    private let importService: ImportServicing
    private let configRepository: ConfigRepository
    private let activity: ActivityCenter?

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
        activity: ActivityCenter? = nil
    ) {
        self.importService = importService
        self.configRepository = configRepository
        self.activity = activity
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

        await runImport(directory: rootURL, title: "Scan “\(rootURL.lastPathComponent)”")
    }

    /// Import from a specific directory (for manual folder selection).
    @MainActor
    func importFromDirectory(_ directory: URL) async {
        await runImport(directory: directory, title: "Scan “\(directory.lastPathComponent)”")
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
    private func runImport(directory: URL, title: String) async {
        isImporting = true
        errorMessage = nil
        lastResult = nil
        progress = nil

        // Activity (W3-ACT): `Scan “‹folder›”`; Cancel stops after the current file and keeps
        // what was imported (`ImportService` checks cancellation per file).
        let box = importTaskBox
        let job = activity?.begin(
            .folderScan, title: title, subject: .folder(directory), itemNoun: .file,
            controls: ActivityControls(cancelStyle: .afterThisFile, cancel: { box.task?.cancel() })
        )
        currentOperationID = job?.id

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.importService.importDirectory(directory) { [weak self] progress in
                    job?.update(ActivityProgress(completed: progress.processed, total: progress.total > 0 ? progress.total : nil,
                                                 currentItem: progress.currentFile ?? progress.phase))
                    Task { @MainActor in self?.progress = progress }
                }

                await MainActor.run {
                    self.lastResult = result
                    self.progress = nil

                    if result.cancelled {
                        job?.cancelled(Self.activityResult(for: result))
                    } else {
                        job?.finish(Self.activityResult(for: result))
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
                        job?.cancelled()
                    } else {
                        job?.fail(cause: Self.plainCause(error, folder: directory), fix: .runAgain)
                        self.errorMessage = error.localizedDescription
                    }
                    self.isImporting = false
                    self.currentOperationID = nil
                }
            }
        }
        box.task = task
        job?.setControls(ActivityControls(
            cancelStyle: .afterThisFile, cancel: { box.task?.cancel() },
            // Strong: a throwaway importer (Folders) must still run again (W3-ACT S5).
            runAgain: { Task { @MainActor in await self.importFromDirectory(directory) } }
        ))

        await task.value
    }

    /// A failure in plain words: a missing folder (usually its drive) or the cause.
    static func plainCause(_ error: Error, folder: URL) -> String {
        if !FileManager.default.fileExists(atPath: folder.path) {
            return "“\(folder.lastPathComponent)” isn’t reachable"
        }
        return error.localizedDescription
    }
}
