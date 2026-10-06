import Foundation

// Small, pure adapters that turn the reports of other areas' jobs into Activity results, so the
// call sites stay one or two lines (thin registration, W3-ACT).

// MARK: - Tag writes (W2-E hook)

enum TagWriteActivity {
    /// Starts the automatic `Write tags to files` operation of one flush.
    static func begin() -> ActivityOperationHandle {
        ActivityCenter.shared.begin(
            .tagWrite, title: "Write tags to files", subject: .allTracks, itemNoun: .file,
            controls: ActivityControls(cancelStyle: .afterThisFile,
                                       cancel: { Task { @MainActor in TagWriteQueue.shared.cancel() } }),
            automatic: true, graceful: true)
    }

    /// `27 files updated · 2 failed`; failures grouped by their plain reason (W2-E words).
    static func end(_ job: ActivityOperationHandle, with report: TagFlushReport, error: Error? = nil) {
        // A database error is a failure with its cause, not a cancel (N11).
        if let error {
            job.fail(cause: "Tag changes couldn’t be written — \(error.localizedDescription)")
            return
        }
        var groups = report.failures
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ActivityFailureGroup(cause: $0.key, count: $0.value, isRetryable: false) }
        if report.missing > 0 {
            groups.append(ActivityFailureGroup(cause: TagWriteFailure.fileMissing.reason, count: report.missing, isRetryable: false))
        }
        let result = ActivityResult(
            counts: [ActivityCount(.done, report.written, "updated"),
                     ActivityCount(.failed, report.failedCount, "failed"),
                     ActivityCount(.skipped, report.deferred, "put off while playing")],
            failureGroups: groups)
        switch report.outcome {
        case .finished:
            job.finish(result)
        case .cancelled, .rootLost, .waitingForFileCheck:
            // The rest waits (it is written when the folder is back) — never a failure.
            job.cancelled(result)
        case .toolMissing:
            job.fail(cause: TagWriteFailure.toolMissing.reason, fix: .openSettings(SettingsTab.sources.rawValue))
        case .disabled, .unreachable:
            job.discard()
        }
    }
}

/// `3 tag changes waiting for “Lexxar”` (UC-JOB-10, P-ACTIVITY-OPS.N09): while tag changes wait
/// for the library drive, a standing queued operation says so in Needs attention and the
/// toolbar; it disappears when they are written.
@MainActor
final class TagWriteWaitActivity {
    static let shared = TagWriteWaitActivity()
    private var job: ActivityOperationHandle?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.pendingTagWritesDidChange, .libraryDriveDidMount, .libraryDriveDidUnmount] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TagWriteWaitActivity.shared.refresh() }
            })
        }
        refresh()
    }

    func refresh(container: DependencyContainer = .shared) {
        let pending = TagWriteQueue.shared.pendingCount
        let drive = container.mountObserver
        let away = !(container.isLibraryDriveMounted)
        let volume = (drive?.watchedLibraryRoot).flatMap { MountObserver.extractVolumePath(from: $0) }
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        if pending > 0, away, let volume {
            if job == nil {
                job = ActivityCenter.shared.begin(
                    .tagWrite, title: "Write tags to files", subject: .allTracks,
                    progress: ActivityProgress(waiting: pending), itemNoun: .tagChange,
                    automatic: true, persists: false)
            }
            job?.update(ActivityProgress(waiting: pending))
            job?.setWaiting(.drive(volumeName: volume))
        } else if let job {
            job.discard()
            self.job = nil
        }
    }
}

// MARK: - Maintenance runs

enum MaintenanceActivity {
    /// `9,412 analysed · 31 failed` — or `Stopped at 4,120 of 12,935 — done work is kept`.
    static func result(processed: Int, failed: Int, verb: String = "analysed") -> ActivityResult {
        ActivityResult(counts: [ActivityCount(.done, processed, verb), ActivityCount(.failed, failed, "failed")])
    }
}

// MARK: - Info ▸ Analyze (W2-E hook)

/// `Analyse “‹title›”` for Info ▸ Analyze: follows the inspector's own phases (`Analyzing…
/// loudness`) and problems, so Info and Activity say the same. No Cancel: the run has none.
@MainActor
enum InspectorAnalysisActivity {
    static func follow(_ track: Track, id: Int64, in analysis: InspectorAnalysis) {
        let job = ActivityCenter.shared.begin(
            .trackAnalysis, title: "Analyse “\(track.title)”", subject: .tracks([id]),
            progress: ActivityProgress(total: 3), itemNoun: .track, graceful: true)
        observe(job, id: id, analysis: analysis, step: 0)
    }

    private static let steps = ["Analyzing… loudness", "Analyzing… tempo and danceability", "Analyzing… similarity"]

    private static func observe(_ job: ActivityOperationHandle, id: Int64, analysis: InspectorAnalysis, step: Int) {
        let phase = withObservationTracking {
            analysis.phases[id]
        } onChange: {
            Task { @MainActor in
                if let phase = analysis.phases[id] {
                    let index = steps.firstIndex(of: phase) ?? step
                    job.update(completed: index, total: steps.count, currentItem: phase)
                    observe(job, id: id, analysis: analysis, step: index)
                } else if let problem = analysis.problems[id] {
                    job.fail(cause: problem.text, fix: problem == .toolMissing ? .openSettings(SettingsTab.sources.rawValue) : nil)
                } else {
                    job.finish(ActivityResult(counts: [ActivityCount(.done, 1, "analysed")]))
                }
            }
        }
        if phase == nil, step > 0 {
            job.finish(ActivityResult(counts: [ActivityCount(.done, 1, "analysed")]))
        }
    }
}
