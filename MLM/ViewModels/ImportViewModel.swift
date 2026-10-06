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

    /// `Import Files or Folder…` and Finder drops (W3-ADD): files from outside the library
    /// folder are first **copied** into it (`LibraryFileCopier`: the importer's organised
    /// layout, originals untouched), then imported — one `Scan` operation for both phases, in
    /// the import lane. Files already in the library folder are imported where they are; files
    /// that already are tracks are neither copied nor imported again.
    ///
    /// Cancel stops the copying; what was copied by then is imported all the same (it is in the
    /// library folder) and the result says `‹n› copied and imported · ‹m› not copied` (review
    /// H2). While the library folder can't be reached the operation waits for it (S3).
    /// `repoint(originalPath, organizedPath)` gives a renamed copy (`Title 2.ext`) its own
    /// `organized_path` after the import (S5).
    ///
    /// - Returns: the import result and what the copy phase did; nil when it didn't run.
    @MainActor
    @discardableResult
    func importFilesCopyingIntoLibrary(
        _ files: [URL], title: String, copier: LibraryFileCopier,
        repoint: @escaping @Sendable (_ originalPath: String, _ organizedPath: String) async -> Void = { _, _ in },
        recheckInterval: Duration = .seconds(3)
    ) async -> (result: ImportService.ImportResult, placement: LibraryFileCopier.Placement)? {
        guard !files.isEmpty else { return nil }
        let box = PlacementBox()
        let root = copier.libraryRoot
        let prepare: PrepareFiles = { job, isCancelled in
            var copier = copier
            copier.waitForLibraryFolder = {
                let volume = MountObserver.extractVolumePath(from: root.path)
                    .map { URL(fileURLWithPath: $0).lastPathComponent } ?? root.lastPathComponent
                job?.setWaiting(.drive(volumeName: volume))
                defer { job?.setWaiting(nil) }
                while !FileManager.default.fileExists(atPath: root.path) {
                    if isCancelled() { return false }
                    try? await Task.sleep(for: recheckInterval)
                }
                return !isCancelled()
            }
            let placement = await copier.place(files, progress: { done, name in
                job?.update(ActivityProgress(completed: done, total: files.count,
                                             currentItem: name.isEmpty ? nil : name, detail: "Copying into the library folder"))
            }, isCancelled: isCancelled)
            box.placement = placement
            return PreparedFiles(
                files: placement.toImport,
                wasCancelled: placement.wasCancelled,
                result: { Self.copyResult(placement, import: $0) },
                afterImport: {
                    for renamed in placement.renamed { await repoint(renamed.copy.path, renamed.relativePath) }
                }
            )
        }
        let common = Self.commonFolder(of: files)
        // Files from several disks have no common folder: the subject is `‹n› files`.
        let subject: ActivitySubject? = common.path == "/"
            ? ActivitySubject(kind: .folder, name: ActivityNoun.file.counted(files.count)) : nil
        guard let result = await runImport(directory: common, files: files, title: title,
                                           prepare: prepare, subject: subject) else { return nil }
        return (result, box.placement ?? LibraryFileCopier.Placement())
    }

    /// The operation's result for a copying import: what was copied, imported, renamed, already
    /// there and not copied — failures grouped by kind, each file listed (review S4).
    nonisolated static func copyResult(_ placement: LibraryFileCopier.Placement,
                                       import result: ImportService.ImportResult) -> ActivityResult {
        var counts: [ActivityCount]
        if placement.wasCancelled {
            counts = [ActivityCount(.done, result.succeeded, "copied and imported"),
                      ActivityCount(.failed, placement.notCopiedCount, "not copied")]
        } else {
            counts = [ActivityCount(.done, placement.copied, "copied into the library folder"),
                      ActivityCount(.done, result.succeeded, "imported")]
            if !placement.renamed.isEmpty {
                counts.append(ActivityCount(.done, placement.renamed.count, "copied under a numbered name"))
            }
            counts.append(ActivityCount(.skipped, result.skipped + placement.alreadyInLibrary, "already in the library"))
            counts.append(ActivityCount(.failed, result.failed, "failed"))
            counts.append(ActivityCount(.failed, placement.notCopiedCount, "not copied"))
        }
        var groups: [ActivityFailureGroup] = []
        let unreadable = placement.notCopied.filter { $0.kind == .unreadable }
        if !unreadable.isEmpty {
            groups.append(ActivityFailureGroup(cause: "Couldn’t read the tags", count: unreadable.count, fix: nil, isRetryable: false))
        }
        for (reason, items) in Dictionary(grouping: placement.notCopied.filter { $0.kind == .copyFailed }, by: \.reason)
            .sorted(by: { $0.key < $1.key }) {
            groups.append(ActivityFailureGroup(cause: "Couldn’t copy — \(reason)", count: items.count, fix: nil, isRetryable: false))
        }
        if let stop = placement.stopCause {
            let stopped = placement.notCopied.filter { $0.kind == .diskFull }.count + placement.notReached
            groups.append(ActivityFailureGroup(cause: stop, count: max(stopped, 1), fix: .runAgain, isRetryable: true))
        }
        if let leftover = placement.leftoverTemporaryFiles.first {
            groups.append(ActivityFailureGroup(
                cause: "A temporary copy couldn’t be removed: \(leftover.path)",
                count: placement.leftoverTemporaryFiles.count, fix: nil, isRetryable: false))
        }
        var items = placement.notCopied.map {
            ActivityItemOutcome(word: "Not copied", title: $0.file.lastPathComponent, reason: $0.reason, isFailure: true)
        }
        items += placement.renamed.map {
            ActivityItemOutcome(word: "Copied as “\($0.copy.lastPathComponent)”", title: $0.relativePath,
                                reason: "A different file has the plain name")
        }
        return ActivityResult(counts: counts, failureGroups: groups, items: items)
    }

    /// What a preparation phase hands to the import: the files, whether it was cancelled, the
    /// operation's result and a step after the import.
    struct PreparedFiles: Sendable {
        var files: [URL]
        var wasCancelled = false
        var result: @Sendable (ImportService.ImportResult) -> ActivityResult
        var afterImport: @Sendable () async -> Void = {}
    }

    typealias PrepareFiles = @Sendable (ActivityOperationHandle?, @escaping @Sendable () -> Bool) async -> PreparedFiles

    private final class PlacementBox: @unchecked Sendable {
        var placement: LibraryFileCopier.Placement?
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
    private func runImport(directory: URL, files: [URL]? = nil, title: String,
                           prepare: PrepareFiles? = nil, subject: ActivitySubject? = nil) async -> ImportService.ImportResult? {
        // Activity (W3-ACT): `Scan “‹folder›”`; Cancel stops after the current file and keeps
        // what was imported (`ImportService` checks cancellation per file). One box per run, so
        // cancelling a queued import never stops the running one (W2-H).
        let box = TaskBox()
        let job = activity?.begin(
            .folderScan, title: title, subject: subject ?? .folder(directory),
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
                // W3-ADD: an optional first phase in the same operation (copy into the library folder).
                let prepared: PreparedFiles?
                if let prepare {
                    prepared = await prepare(job, { Task.isCancelled })
                } else {
                    prepared = nil
                }
                let result: ImportService.ImportResult
                if let prepared {
                    // The copies are in the library folder already: they are imported even after a
                    // Cancel during copying (review H2) — never left there unannounced.
                    let service = self.importService
                    let copies = prepared.files
                    result = try await Task.detached { try await service.importFiles(copies, onProgress: onProgress) }.value
                    await prepared.afterImport()
                } else if let files {
                    result = try await self.importService.importFiles(files, onProgress: onProgress)
                } else {
                    result = try await self.importService.importDirectory(directory, onProgress: onProgress)
                }

                await MainActor.run {
                    self.lastResult = result
                    outcome.result = result
                    self.progress = nil
                    let activityResult = prepared.map { $0.result(result) } ?? Self.activityResult(for: result)
                    let cancelledCopying = prepared?.wasCancelled ?? false

                    if result.cancelled && prepared == nil {
                        job?.cancelled(activityResult)
                    } else {
                        if cancelledCopying { job?.cancelled(activityResult) } else { job?.finish(activityResult) }
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
                    if let files, let prepare {
                        await self.runImport(directory: directory, files: files, title: title, prepare: prepare, subject: subject)
                    } else if let files {
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
