import SwiftUI

/// Registers the jobs of Settings ▸ Maintenance with Activity (W3-ACT, DEC-044) from the pane's
/// existing state (`isRunning` action key, its progress and result line) — a thin adapter, so
/// the pane needs no rewrite until W3-SET. Cancel is offered only for the runs whose work really
/// stops on it (the analyses and the artwork runs check cancellation per track; the path
/// migration can't stop half-way; the metadata rescan has no cancel).
struct MaintenanceActivityTracking: ViewModifier {
    let running: String?
    let progress: MaintenanceProgressTracker.ProgressState?
    let result: String?
    let cancel: @MainActor () -> Void

    @State private var job: ActivityOperationHandle?
    @State private var cancelRequested = false

    func body(content: Content) -> some View {
        content
            .onChange(of: running) { old, new in
                if let job, old != nil {
                    MaintenanceJob(action: old ?? "").end(job, message: result, cancelled: cancelRequested)
                    self.job = nil
                }
                if let new { start(new) }
            }
            .onChange(of: progress?.current) { _, _ in
                guard let job, let progress, progress.total > 0 else { return }
                let item = [progress.currentTrackArtist, progress.currentTrackTitle].filter { !$0.isEmpty }.joined(separator: " — ")
                job.update(completed: progress.current, total: progress.total, currentItem: item.isEmpty ? nil : item)
            }
    }

    private func start(_ action: String) {
        let kind = MaintenanceJob(action: action)
        cancelRequested = false
        let cancel = self.cancel
        let flag = $cancelRequested
        job = ActivityCenter.shared.begin(
            kind.kind, title: kind.title, subject: .settings(.maintenance), itemNoun: .track,
            controls: kind.isCancellable
                ? ActivityControls(cancel: { Task { @MainActor in flag.wrappedValue = true; cancel() } })
                : .none,
            graceful: kind.isShort)
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
    /// `ffmpeg not found. Install via: brew install ffmpeg`).
    func end(_ job: ActivityOperationHandle, message: String?, cancelled: Bool) {
        let text = message ?? ""
        let failed = Self.number(before: "failed", in: text) ?? 0
        let done = Self.number(before: "analyzed", in: text) ?? Self.number(before: "processed", in: text)
            ?? Self.number(before: "updated", in: text) ?? Self.number(before: "fetched", in: text)
            ?? Self.number(before: "organized paths", in: text)
        let lower = text.lowercased()
        if cancelled || lower.contains("cancel") {
            job.cancelled(ActivityResult(summary: "Stopped — done work is kept"))
        } else if lower.contains("not found") && done == nil || lower.contains("failed:") || lower.contains("not available")
                    || lower.contains("did not start") {
            let tool = lower.contains("not found") || lower.contains("not available")
            job.fail(cause: Self.plain(text), fix: tool ? .openSettings(SettingsTab.sources.rawValue) : .runAgain)
        } else {
            var counts: [ActivityCount] = []
            if let done { counts.append(ActivityCount(.done, done, kind == .artwork ? "fetched" : (kind == .pathMigration ? "updated" : "analysed"))) }
            counts.append(ActivityCount(.failed, failed, "failed"))
            let groups = failed > 0 ? [ActivityFailureGroup(cause: "Couldn’t be analysed — the details are in the log", count: failed, fix: .runAgain)] : []
            job.finish(ActivityResult(counts: counts, failureGroups: groups,
                                      summary: done == nil && !text.isEmpty ? Self.plain(text) : nil))
        }
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
