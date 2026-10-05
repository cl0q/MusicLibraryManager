import Foundation
import Observation

extension Notification.Name {
    /// Posted (main thread) after a file check or a use-time miss changed the persisted
    /// availability of at least one track. Track lists refresh in place.
    /// `userInfo["changed"]`: `Int` rows changed.
    static let trackAvailabilityDidChange = Notification.Name("MLMTrackAvailabilityDidChange")
}

/// Keeps the persisted availability fresh: decides **when** `TrackAvailabilityReconciler`
/// runs and reports it in the status bar (UC-STATUS-06). One per library (owned by
/// `DependencyContainer`).
///
/// Triggers (each coalesced, at most one run at a time, a request during a run queues one more):
/// - library open, if the library folder is reachable (`start()`)
/// - `.libraryDidImport` — scan/import, Scan Library Folder ⌘R, organized-path migration and
///   repairs in Settings ▸ Maintenance (they post it) → full check
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

    /// Phase text of the status bar while a check runs.
    static let loadingPhase = "Checking files…"

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
        let full: [Notification.Name] = [.libraryDidImport, .libraryDriveDidMount, .libraryRootDidChange]
        for name in full {
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

    /// Ask for a check (the manual re-check hook; ⌘R Scan reaches it through `.libraryDidImport`).
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

    /// Run the pending check now and wait for it (tests, and the hook for an explicit command).
    func checkNow(_ scope: TrackFileCheckScope = .all) async {
        pendingScope = Self.merge(pendingScope, scope)
        scheduledTask?.cancel()
        if let runningTask { await runningTask.value }
        runPending()
        await runningTask?.value
    }

    /// Playback or a file action met a missing file: record it — only if the library folder is
    /// reachable now (else it is the drive, DEC-014). Returns whether the row changed.
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
        // W3-ACT: register an Activity operation for the file check here (DEC-044) — start it
        // with the scope, report `checked of total` from the progress callback, finish it with
        // the report's counts. Until then the status-bar loading phase is the only feedback.
        let reconciler = self.reconciler
        let libraryRoot = self.libraryRoot
        runningTask = Task { [weak self] in
            var report: TrackAvailabilityReconciler.Report?
            if let root = await libraryRoot(), !root.isEmpty {
                // The reconciler is an actor: the disk work runs off the main actor.
                report = await reconciler.reconcile(libraryRoot: root, scope: scope)
            }
            self?.finish(report)
        }
    }

    private func finish(_ report: TrackAvailabilityReconciler.Report?) {
        runningTask = nil
        isChecking = false
        if let report {
            lastReport = report
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
