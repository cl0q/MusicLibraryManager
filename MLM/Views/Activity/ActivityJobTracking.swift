import Observation
import SwiftUI

/// Runs the jobs of Settings ▸ Maintenance and Library ▸ Maintenance ▸ and registers each as an
/// Activity operation (W3-ACT, DEC-044). It owns the tasks, the operation handles and the job
/// state (running action, progress, result line), so closing Settings or switching tabs neither
/// stops a job nor leaves its operation Running: the operation begins and ends inside the task
/// that does the work (B3).
///
/// W3-SET: jobs **queue** instead of being refused (ST-MAINT: "no one-at-a-time lock — jobs
/// queue"): every job joins the `maintenance` lane, so a second one is `Queued · Starts after …`
/// and starts by itself. Settings rows read `echo(for:)` / `lastRun(of:)` — the same words and
/// numbers as Activity (UC-JOB-07). Cancel is offered only where the work really stops on it
/// (the analyses and the artwork runs check cancellation per track; the path migration can't stop
/// half-way; rereading tags has no cancel); a queued job can always be cancelled.
@MainActor
@Observable
final class MaintenanceJobRunner {
    static let shared = MaintenanceJobRunner()

    /// Every Maintenance job waits for the one before it.
    static let lane = ActivityLane("maintenance")

    /// The running action key (`fingerprint`, `path-apply`, …).
    var running: String?
    var progress: MaintenanceProgressTracker.ProgressState? {
        didSet { reportProgress() }
    }
    /// The running job's result line (read when it ends; the pane no longer shows it).
    var resultMessage: String?
    /// Queued and running jobs → their operation (observable, for the rows).
    private(set) var operationIDs: [String: UUID] = [:]

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var handles: [String: ActivityOperationHandle] = [:]
    /// The action whose work is executing now.
    @ObservationIgnored private var current: String?
    @ObservationIgnored private(set) var cancelRequested = false
    @ObservationIgnored let center: ActivityCenter

    init(center: ActivityCenter = .shared) {
        self.center = center
    }

    var isBusy: Bool { !tasks.isEmpty }

    /// Whether `action` is queued or running.
    func isActive(_ action: String) -> Bool { operationIDs[action] != nil }

    /// Starts `work` as the job `action`, or queues it behind the running one. An action that
    /// is already queued or running isn't started twice.
    func run(_ action: String, _ work: @escaping @MainActor () async -> Void) {
        guard tasks[action] == nil else { return }
        let kind = MaintenanceJob(action: action)
        let job = center.begin(
            kind.kind, title: kind.title, subject: .settings(.maintenance), itemNoun: .track,
            controls: kind.isCancellable
                ? ActivityControls(cancel: { [weak self] in Task { @MainActor in self?.cancel(action) } })
                : .none,
            lane: Self.lane,
            graceful: kind.isShort)
        handles[action] = job
        operationIDs[action] = job.id
        tasks[action] = Task { [weak self] in
            // Queued behind another Maintenance job (cancelled while queued → never runs).
            guard await job.waitForTurn(), let self else {
                self?.forget(action)
                return
            }
            self.current = action
            self.cancelRequested = false
            self.resultMessage = nil
            self.progress = nil
            self.running = action
            await work()
            self.finish(action)
        }
    }

    /// The running job's Cancel (pane and Activity): the task really stops; the operation ends
    /// as Cancelled when the work returns.
    func cancel() {
        guard let current else { return }
        cancel(current)
    }

    /// Cancel one job: a queued one ends at once (`Cancelled before it started`), a running one
    /// only when its work can stop.
    func cancel(_ action: String) {
        guard let job = handles[action] else { return }
        if current != action {
            center.cancel(job.id)
            return
        }
        guard MaintenanceJob(action: action).isCancellable else { return }
        cancelRequested = true
        tasks[action]?.cancel()
    }

    /// Whether `Cancel` really stops `action` now (queued: always; running: when it can).
    func canCancel(_ action: String) -> Bool {
        guard handles[action] != nil else { return false }
        return current != action || MaintenanceJob(action: action).isCancellable
    }

    /// Waits for every queued and running job (tests).
    func waitUntilIdle() async {
        while let task = tasks.values.first {
            await task.value
        }
    }

    private func finish(_ action: String) {
        if let job = handles[action] {
            MaintenanceJob(action: action).end(job, message: resultMessage, cancelled: cancelRequested)
        }
        if running == action { running = nil }
        progress = nil
        current = nil
        forget(action)
    }

    private func forget(_ action: String) {
        handles[action] = nil
        operationIDs[action] = nil
        tasks[action] = nil
    }

    private func reportProgress() {
        guard let current, let job = handles[current], let progress, progress.total > 0 else { return }
        let item = [progress.currentTrackArtist, progress.currentTrackTitle].filter { !$0.isEmpty }.joined(separator: " — ")
        job.update(completed: progress.current, total: progress.total, currentItem: item.isEmpty ? nil : item)
    }

    // MARK: - Echo (UC-JOB-07)

    /// What a Maintenance row shows while its job is queued or running, in Activity's words.
    struct Echo: Equatable {
        /// `Running — 1,204 of 3,523` · `Queued · Starts after “ReplayGain analysis”`.
        let text: String
        let fraction: Double?
        let isQueued: Bool
    }

    func echo(for action: String) -> Echo? {
        guard let id = operationIDs[action] else { return nil }
        guard let op = center.operation(id: id) else {
            // Inside its grace period (a short job): running, nothing to count yet.
            return Echo(text: "Running…", fraction: nil, isQueued: false)
        }
        return Self.echo(op)
    }

    /// The echo of any active operation (also the automatic artwork backfill).
    static func echo(_ op: ActivityOperation) -> Echo? {
        guard op.state.isActive else { return nil }
        if op.state != .running, let wait = op.wait {
            return Echo(text: "Queued · \(wait.sentence)", fraction: nil, isQueued: true)
        }
        if let progress = ActivityPresentation.progressText(op.progress) {
            return Echo(text: "Running — \(progress)", fraction: op.progress.fraction, isQueued: false)
        }
        return Echo(text: "Running…", fraction: nil, isQueued: false)
    }

    /// `last run 28 Sep 2026 — 3,204 analysed · 12 failed` from Activity's history (the job's
    /// own result, kept per job — ST-MAINT.E13).
    func lastRun(of action: String) -> String? {
        let job = MaintenanceJob(action: action)
        guard let op = center.finishedOperations.first(where: { $0.kind == job.kind && $0.title == job.title }) else {
            return nil
        }
        return Self.lastRunText(op)
    }

    static func lastRunText(_ op: ActivityOperation) -> String {
        let date = (op.endedAt ?? op.startedAt).formatted(date: .abbreviated, time: .omitted)
        let result = ActivityPresentation.resultText(op)
        switch op.state {
        case .cancelled:
            return "last run \(date) — cancelled" + (result.map { " · \($0)" } ?? "")
        case .failed:
            return "last run \(date) — failed" + (result.map { ": \($0)" } ?? "")
        default:
            return "last run \(date) — " + (result ?? "completed")
        }
    }
}

/// One Maintenance action key → its Activity kind, title and honest controls.
struct MaintenanceJob: Equatable {
    let action: String

    var kind: ActivityKind {
        switch action {
        case "artwork-embedded", "artwork-musicbrainz": .artwork
        case "path-audit", "path-apply", "path-rollback": .pathMigration
        default: .maintenanceAnalysis
        }
    }

    var title: String {
        switch action {
        case "fingerprint": "Fingerprint all tracks"
        case "replaygain": "ReplayGain analysis"
        case "danceability": "Danceability analysis"
        case "groove": "Similarity analysis"
        case "artwork-embedded": "Refresh embedded artwork"
        case "artwork-musicbrainz": "Fetch artwork from MusicBrainz"
        case "path-audit": "Preview organized-path changes"
        case "path-apply": "Update organized paths"
        case "path-rollback": "Roll back last path migration"
        case "rescan": "Reread tags from files"
        case "create-liked-playlist": "Recreate the Liked playlist"
        default: action
        }
    }

    var isCancellable: Bool {
        // `rescan` stops after the current file (review S2).
        ["fingerprint", "replaygain", "danceability", "groove", "artwork-embedded", "artwork-musicbrainz", "rescan"].contains(action)
    }

    var isShort: Bool { ["path-audit", "create-liked-playlist"].contains(action) }

    /// Ends the operation from the pane's result line (`ReplayGain: 9,412 analyzed, 31 failed`,
    /// `ffmpeg not found. Install via: brew install ffmpeg`). A run that returned without a line
    /// (its preconditions weren't met) leaves no trace.
    func end(_ job: ActivityOperationHandle, message: String?, cancelled: Bool) {
        guard message != nil || cancelled else {
            job.discard()
            return
        }
        let text = message ?? ""
        let failed = Self.number(before: "failed", in: text) ?? 0
        let done = Self.number(before: "analyzed", in: text) ?? Self.number(before: "processed", in: text)
            ?? Self.number(before: "updated", in: text) ?? Self.number(before: "fetched", in: text)
            ?? Self.number(before: "organized paths", in: text)
        let lower = text.lowercased()
        if cancelled {
            var counts: [ActivityCount] = []
            if let done { counts.append(ActivityCount(.done, done, verb)) }
            job.cancelled(ActivityResult(counts: counts, summary: done == nil ? "Stopped — done work is kept" : nil))
        } else if (lower.contains("not found") && done == nil) || lower.contains("failed:") || lower.contains("not available")
                    || lower.contains("did not start") || lower.contains("cancelled:") {
            let tool = lower.contains("not found") || lower.contains("not available")
            job.fail(cause: Self.plain(text), fix: tool ? .openSettings(SettingsTab.sources.rawValue) : nil)
        } else {
            var counts: [ActivityCount] = []
            if let done { counts.append(ActivityCount(.done, done, verb)) }
            counts.append(ActivityCount(.failed, failed, "failed"))
            let groups = failed > 0 ? [ActivityFailureGroup(cause: "Couldn’t be analysed — the details are in the log", count: failed)] : []
            job.finish(ActivityResult(counts: counts, failureGroups: groups,
                                      summary: done == nil && !text.isEmpty ? Self.plain(text) : nil))
        }
    }

    private var verb: String {
        if action == "artwork-embedded" { return "read" }
        if action == "rescan" { return "updated" }
        return kind == .artwork ? "fetched" : (kind == .pathMigration ? "updated" : "analysed")
    }

    /// The integer right before `word` (`31 failed` → 31).
    static func number(before word: String, in text: String) -> Int? {
        guard let range = text.range(of: "([0-9][0-9,.]*) \(word)", options: .regularExpression) else { return nil }
        let digits = text[range].prefix { $0 != " " }.filter(\.isNumber)
        return Int(digits)
    }

    /// The pane's line without its `Label:` prefix.
    static func plain(_ text: String) -> String {
        guard let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) < 30 else { return text }
        return text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
}
