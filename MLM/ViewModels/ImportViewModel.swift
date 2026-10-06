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

    // MARK: - Library folder change (S-SET-LIBFOLDER, W3-SET)

    /// How many of the library's files a candidate library folder holds — the quick check of the
    /// consequences sheet before anything is saved (S-SET-LIBFOLDER.N01).
    struct FolderComparison: Equatable, Sendable {
        let found: Int
        let total: Int
        var missing: Int { total - found }
    }

    /// Compares `folder` with the stored track locations (`organized_path`, relative to the
    /// library folder; an absolute path outside it is checked as it is). Reads no file contents.
    nonisolated static func compare(folder: URL, organizedPaths: [String],
                                    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> FolderComparison {
        let root = folder.standardizedFileURL.path
        var found = 0
        for path in organizedPaths where !path.isEmpty {
            if path.hasPrefix("/"), fileExists(path) {
                found += 1
                continue
            }
            let relative = path.hasPrefix("/") ? String(path.drop(while: { $0 == "/" })) : path
            if fileExists(root + "/" + relative) { found += 1 }
        }
        return FolderComparison(found: found, total: organizedPaths.filter { !$0.isEmpty }.count)
    }

    /// `Change Folder`: the new folder becomes the base of every track's location (existing tracks
    /// keep their relative paths); the file check runs after (`.libraryRootDidChange` →
    /// `LibraryAvailabilityMonitor`), then — when asked — a scan of the new folder.
    @MainActor
    func changeLibraryFolder(to folder: URL, scanAfterwards: Bool) async {
        await setLibraryRoot(folder.standardizedFileURL.path)
        guard errorMessage == nil, scanAfterwards else { return }
        await importLibrary()
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

    /// Import audio files dropped from Finder (W2-H): the same `Scan` operation as a folder,
    /// counted in files. Queues behind a running import (one import lane).
    ///
    /// - Returns: the result, or nil when it didn't run (cancelled while queued, or failed).
    @MainActor
    @discardableResult
    func importFiles(_ files: [URL], title: String) async -> ImportService.ImportResult? {
        guard !files.isEmpty else { return nil }
        return await runImport(directory: Self.commonFolder(of: files), files: files, title: title)
    }

    /// Imports run one at a time; a second one is `Queued` behind the running one instead of
    /// overwriting its state (UC-JOB-03, PP-ACTIVITY-05).
    static let lane = ActivityLane("imports")

    /// The deepest folder that holds every file (the Activity subject of a file drop).
    static func commonFolder(of files: [URL]) -> URL {
        let paths = files.map { $0.deletingLastPathComponent().standardizedFileURL.pathComponents }
        guard var common = paths.first else { return URL(fileURLWithPath: "/") }
        for components in paths.dropFirst() {
            common = zip(common, components).prefix { $0 == $1 }.map(\.0)
        }
        return URL(fileURLWithPath: NSString.path(withComponents: common.isEmpty ? ["/"] : common))
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
    @discardableResult
    private func runImport(directory: URL, files: [URL]? = nil, title: String) async -> ImportService.ImportResult? {
        // Activity (W3-ACT): `Scan “‹folder›”`; Cancel stops after the current file and keeps
        // what was imported (`ImportService` checks cancellation per file). One box per run, so
        // cancelling a queued import never stops the running one (W2-H).
        let box = TaskBox()
        let job = activity?.begin(
            .folderScan, title: title, subject: .folder(directory),
            progress: files.map { ActivityProgress(completed: 0, total: $0.count, currentItem: nil) } ?? .indeterminate,
            itemNoun: .file,
            controls: ActivityControls(cancelStyle: .afterThisFile, cancel: { box.task?.cancel() }),
            lane: Self.lane
        )
        // A second import waits for its turn instead of overwriting this view model's state.
        if let job, !(await job.waitForTurn()) { return nil }

        isImporting = true
        errorMessage = nil
        lastResult = nil
        progress = nil
        importTaskBox = box
        currentOperationID = job?.id
        let outcome = ResultBox()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let onProgress: @Sendable (ImportService.ImportProgress) -> Void = { [weak self] progress in
                    job?.update(ActivityProgress(completed: progress.processed, total: progress.total > 0 ? progress.total : nil,
                                                 currentItem: progress.currentFile ?? progress.phase))
                    Task { @MainActor in self?.progress = progress }
                }
                let result = if let files {
                    try await self.importService.importFiles(files, onProgress: onProgress)
                } else {
                    try await self.importService.importDirectory(directory, onProgress: onProgress)
                }

                await MainActor.run {
                    self.lastResult = result
                    outcome.result = result
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
            runAgain: {
                Task { @MainActor in
                    if let files {
                        await self.importFiles(files, title: title)
                    } else {
                        await self.importFromDirectory(directory)
                    }
                }
            }
        ))

        await task.value
        return outcome.result
    }

    /// The result of one run, read after its task ends (a queued run may already have reset
    /// `lastResult` by the time a caller reads it).
    private final class ResultBox: @unchecked Sendable {
        var result: ImportService.ImportResult?
    }

    /// A failure in plain words: a missing folder (usually its drive) or the cause.
    static func plainCause(_ error: Error, folder: URL) -> String {
        if !FileManager.default.fileExists(atPath: folder.path) {
            return "“\(folder.lastPathComponent)” isn’t reachable"
        }
        return error.localizedDescription
    }
}
