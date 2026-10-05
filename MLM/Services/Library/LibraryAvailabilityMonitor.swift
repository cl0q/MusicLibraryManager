import Foundation
import Observation

extension Notification.Name {
    /// Posted (main thread) after a file check or a use-time miss changed the persisted
    /// availability of at least one track. Track lists refresh in place.
    /// `userInfo["changed"]`: `Int` rows changed.
    static let trackAvailabilityDidChange = Notification.Name("MLMTrackAvailabilityDidChange")

    /// Post (main thread) when **files** in the library folder were added, moved or re-pointed:
    /// a scan or import of files, the organized-path migration and its rollback. It asks for a
    /// full file check. Metadata edits, tag writes, genre merges, review decisions and analysis
    /// post `.libraryDidImport` only and never cause a file check (S6, W2-A review).
    static let libraryFilesDidChange = Notification.Name("MLMLibraryFilesDidChange")
}

/// Keeps the persisted availability fresh: decides **when** `TrackAvailabilityReconciler`
/// runs and reports it in the status bar (UC-STATUS-06). One per library (owned by
/// `DependencyContainer`).
///
/// Triggers (each coalesced, at most one run at a time, a request during a run queues one more):
/// - library open, if the library folder is reachable (`start()`)
/// - `.libraryFilesDidChange` — scan/import of files, Scan Library Folder ⌘R, organized-path
///   migration and rollback → full check (`.libraryDidImport` alone — edits, analysis — doesn't)
/// - `.libraryDriveDidMount` (and `Try Again` on the banner) → full check
/// - `.libraryRootDidChange` → full check of the new folder
/// - `.downloadDidComplete` → re-check only the tracks flagged missing (a download writes its
///   own path and clears its flag in `TrackRepository.markAsDownloaded`)
///
/// Nothing runs while the library folder is unreachable; the reconciler checks again before
/// and after every batch.
@MainActor
@Observable
final class LibraryAvailabilityMonitor {
    /// A file check is running (drives the status-bar loading phase).
    private(set) var isChecking = false
    /// The last finished run.
    private(set) var lastReport: TrackAvailabilityReconciler.Report?
    /// Counts runs stopped as suspicious; the status bar shows a sentence when it grows.
    private(set) var suspiciousStops = 0
    /// The library folder of the last suspicious stop.
    private(set) var suspiciousFolder: String?

    /// What starts a full check: files changed, the disk came back, another library folder.
    /// Not `.libraryDidImport` — it is also posted for edits and analysis (S6).
    static let fullCheckTriggers: [Notification.Name] = [.libraryFilesDidChange, .libraryDriveDidMount, .libraryRootDidChange]

    /// Phase text of the status bar while a check runs.
    static let loadingPhase = "Checking files…"

    /// `File check stopped — most files weren’t found in “Music”. Check the library folder in
    /// Settings.` (two sentences, so with periods, UC-COPY-04)
    static func suspiciousStopMessage(folder: String) -> String {
        let name = folder.isEmpty ? "the library folder" : "“\(URL(fileURLWithPath: folder).lastPathComponent)”"
        return "File check stopped — most files weren’t found in \(name). Check the library folder in Settings."
    }

    @ObservationIgnored private let reconciler: TrackAvailabilityReconciler
    @ObservationIgnored private let repository: TrackRepository
    @ObservationIgnored private let libraryRoot: @MainActor () async -> String?
    @ObservationIgnored private let coalesceDelay: Duration
    @ObservationIgnored private var runningTask: Task<Void, Never>?
    @ObservationIgnored private var pendingScope: TrackFileCheckScope?
    @ObservationIgnored private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(
        reconciler: TrackAvailabilityReconciler,
        repository: TrackRepository,
        libraryRoot: @escaping @MainActor () async -> String?,
        coalesceDelay: Duration = .seconds(2)
    ) {
        self.reconciler = reconciler
        self.repository = repository
        self.libraryRoot = libraryRoot
        self.coalesceDelay = coalesceDelay
    }

    /// Start observing the triggers and check once now (library open).
    func start(initialDelay: Duration = .seconds(3)) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in Self.fullCheckTriggers {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.request(.all) }
            })
        }
        observers.append(center.addObserver(forName: .downloadDidComplete, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.request(.flaggedMissing) }
        })
        // The drive went away: stop at once (the reconciler would also stop at the next batch).
        observers.append(center.addObserver(forName: .libraryDriveDidUnmount, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRunningCheck() }
        })
        request(.all, after: initialDelay)
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        scheduledTask?.cancel()
        runningTask?.cancel()
    }

    /// Cancel the running check (its finished batches stay; nothing half-written).
    func cancelRunningCheck() {
        scheduledTask?.cancel()
        pendingScope = nil
        runningTask?.cancel()
    }

    /// Ask for a check (the manual re-check hook; ⌘R Scan reaches it through `.libraryFilesDidChange`).
    /// Requests within `coalesceDelay` merge; `.all` wins over narrower scopes.
    func request(_ scope: TrackFileCheckScope, after delay: Duration? = nil) {
        pendingScope = Self.merge(pendingScope, scope)
        guard runningTask == nil else { return }  // picked up when the running check ends
        scheduledTask?.cancel()
        let wait = delay ?? coalesceDelay
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.runPending()
        }
    }

    /// Run the pending check now, wait for it and return its report (`skippedRootUnreachable`
    /// when the folder can't be read). Callers that act on the result (Download Again) go on
    /// only for `.completed`.
    @discardableResult
    func checkNow(_ scope: TrackFileCheckScope = .all) async -> TrackAvailabilityReconciler.Report {
        pendingScope = Self.merge(pendingScope, scope)
        scheduledTask?.cancel()
        if let runningTask { await runningTask.value }
        runPending()
        await runningTask?.value
        return lastReport ?? TrackAvailabilityReconciler.Report(outcome: .skippedRootUnreachable)
    }

    /// Whether the library folder can be read now (checked off the main actor).
    func isLibraryFolderReachable() async -> Bool {
        guard let root = await libraryRoot() else { return false }
        return await reconciler.isLibraryRootReachable(root)
    }

    /// Playback or a file action met a missing file: record it — only if the library folder is
    /// reachable now (else it is the drive, DEC-014). Returns whether the row changed.
    /// No caller yet: W2-C calls it when playback can't open a track's file.
    @discardableResult
    func recordMissingAtUse(trackID: Int64) async -> Bool {
        guard let root = await libraryRoot(), await reconciler.isLibraryRootReachable(root) else { return false }
        let changed = (try? await repository.recordFileMissing(trackId: trackID)) ?? false
        if changed {
            NotificationCenter.default.post(name: .trackAvailabilityDidChange, object: nil, userInfo: ["changed": 1])
        }
        return changed
    }

    static func merge(_ lhs: TrackFileCheckScope?, _ rhs: TrackFileCheckScope) -> TrackFileCheckScope {
        switch (lhs, rhs) {
        case (nil, let scope): return scope
        case (.all?, _), (_, .all): return .all
        case (.flaggedMissing?, .flaggedMissing): return .flaggedMissing
        case (.tracks(let a)?, .tracks(let b)): return .tracks(a.union(b))
        default: return .all
        }
    }

    // MARK: - Running

    private func runPending() {
        guard runningTask == nil, let scope = pendingScope else { return }
        pendingScope = nil
        isChecking = true
        // Activity (W3-ACT, DEC-044): an automatic `Check files` operation, visible only when it
        // takes longer than a moment; Cancel stops it (no file is flagged by a partial run).
        let job = ActivityCenter.shared.begin(
            .fileCheck, title: "Check files", subject: .allTracks, itemNoun: .file,
            controls: ActivityControls(cancel: { [weak self] in Task { @MainActor in self?.cancelRunningCheck() } }),
            automatic: true, graceful: true)
        let reconciler = self.reconciler
        let libraryRoot = self.libraryRoot
        runningTask = Task { [weak self] in
            var report = TrackAvailabilityReconciler.Report(outcome: .skippedRootUnreachable)
            let root = await libraryRoot() ?? ""
            if !root.isEmpty {
                // The reconciler is an actor: the disk work runs off the main actor.
                report = await reconciler.reconcile(libraryRoot: root, scope: scope) { done, total in
                    job.update(completed: done, total: total)
                }
            }
            Self.end(job, with: report)
            self?.finish(report, root: root)
        }
    }

    /// The file check's result in Activity: `12,935 checked · 3 missing · 2 back`. A check that
    /// couldn't run because the folder is away leaves no trace (it isn't a failure, UC-JOB-10).
    nonisolated static func end(_ job: ActivityOperationHandle, with report: TrackAvailabilityReconciler.Report) {
        let result = ActivityResult(counts: [
            ActivityCount(.done, report.checked, "checked"),
            ActivityCount(.done, report.flaggedMissing, "missing"),
            ActivityCount(.done, report.cleared, "back"),
            ActivityCount(.skipped, report.skipped, "on a disk that isn’t connected"),
        ])
        switch report.outcome {
        case .completed: job.finish(result)
        case .skippedRootUnreachable: job.discard()
        case .cancelled: job.cancelled(result)
        case .abortedRootLost:
            job.cancelled(ActivityResult(summary: "The library folder went away — nothing was flagged"))
        case .abortedSuspicious:
            job.fail(cause: "Too many files looked missing at once — nothing was flagged. Check the library folder in Settings ▸ Library.",
                     fix: .openSettings(SettingsTab.library.rawValue))
        }
    }

    private func finish(_ report: TrackAvailabilityReconciler.Report, root: String) {
        runningTask = nil
        isChecking = false
        do {
            lastReport = report
            if report.outcome == .abortedSuspicious {
                suspiciousFolder = root
                suspiciousStops += 1
            }
            if report.outcome != .skippedRootUnreachable {
                AppLogger.shared.info(
                    "File check \(report.outcome): \(report.checked) checked, \(report.flaggedMissing) missing, \(report.cleared) back, \(report.skipped) skipped",
                    source: "Availability"
                )
            }
            if report.changedRows > 0 {
                NotificationCenter.default.post(
                    name: .trackAvailabilityDidChange, object: nil, userInfo: ["changed": report.changedRows]
                )
            }
        }
        if let pending = pendingScope { request(pending, after: .zero) }
    }
}
