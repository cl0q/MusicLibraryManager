import Observation
import SwiftUI

/// Runs the jobs of Settings ▸ Maintenance and registers each as an Activity operation
/// (W3-ACT, DEC-044). It owns the running task, the operation handle and the pane's job state
/// (running action, progress, result line), so closing Settings or switching tabs neither stops
/// the job nor leaves its operation Running: the operation begins and ends inside the task that
/// does the work (B3). The pane is not redesigned (W3-SET); it reads and writes this state.
/// Cancel is offered only where the work really stops on it (the analyses and the artwork runs
/// check cancellation per track; the path migration can't stop half-way; the metadata rescan has
/// no cancel).
@MainActor
@Observable
final class MaintenanceJobRunner {
    static let shared = MaintenanceJobRunner()

    /// The running action key (`fingerprint`, `path-apply`, …), as the pane shows it.
    var running: String?
    var progress: MaintenanceProgressTracker.ProgressState? {
        didSet { reportProgress() }
    }
    var resultMessage: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var job: ActivityOperationHandle?
    @ObservationIgnored private var action: String?
    @ObservationIgnored private(set) var cancelRequested = false
    @ObservationIgnored let center: ActivityCenter

    init(center: ActivityCenter = .shared) {
        self.center = center
    }

    var isBusy: Bool { task != nil }

    /// Starts `work` (the pane's own run function) as the job `action`. One job at a time.
    func run(_ action: String, _ work: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        let kind = MaintenanceJob(action: action)
        cancelRequested = false
        self.action = action
        job = center.begin(
            kind.kind, title: kind.title, subject: .settings(.maintenance), itemNoun: .track,
            controls: kind.isCancellable
                ? ActivityControls(cancel: { [weak self] in Task { @MainActor in self?.cancel() } })
                : .none,
            graceful: kind.isShort)
        task = Task { [weak self] in
            await work()
            self?.finish()
        }
    }

    /// The pane's Cancel and Activity's Cancel: the task really stops; the operation ends as
    /// Cancelled when the work returns.
    func cancel() {
        guard task != nil, let action, MaintenanceJob(action: action).isCancellable else { return }
        cancelRequested = true
        task?.cancel()
    }

    /// Waits for the running job (tests).
    func waitUntilIdle() async {
        await task?.value
    }

    private func finish() {
        if let job, let action {
            MaintenanceJob(action: action).end(job, message: resultMessage, cancelled: cancelRequested)
        }
        job = nil
        action = nil
        task = nil
    }

    private func reportProgress() {
        guard let job, let progress, progress.total > 0 else { return }
        let item = [progress.currentTrackArtist, progress.currentTrackTitle].filter { !$0.isEmpty }.joined(separator: " — ")
        job.update(completed: progress.current, total: progress.total, currentItem: item.isEmpty ? nil : item)
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
        case "groove": "Similarity analysis (embeddings)"
        case "artwork-embedded": "Refresh embedded artwork"
        case "artwork-musicbrainz": "Fetch artwork from MusicBrainz"
        case "path-audit": "Check file paths"
        case "path-apply": "Reorganise file paths"
        case "path-rollback": "Roll back file paths"
        case "rescan": "Rescan metadata"
        case "create-liked-playlist": "Create the Liked playlist"
        default: action
        }
    }

    var isCancellable: Bool {
        ["fingerprint", "replaygain", "danceability", "groove", "artwork-embedded", "artwork-musicbrainz"].contains(action)
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
        kind == .artwork ? "fetched" : (kind == .pathMigration ? "updated" : "analysed")
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
