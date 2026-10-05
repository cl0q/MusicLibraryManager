import Foundation

/// The words Activity shows — one place, pure, unit-tested — so the toolbar item, the popover,
/// the window, the status bar and the inline echo say the same thing (DEC-044).
enum ActivityPresentation {

    // MARK: - Operation words

    /// `Importing` for a playlist download batch, else the kind's verb.
    static func verb(for operation: ActivityOperation) -> String {
        if operation.kind == .download, operation.subject.kind == .playlist { return "Importing" }
        return operation.kind.activeVerb
    }

    /// `12 of 44` (the item in flight), `212 waiting`, or `nil` when indeterminate.
    static func progressText(_ progress: ActivityProgress) -> String? {
        if let total = progress.total, total > 0 {
            return "\(progress.position.formatted(.number)) of \(total.formatted(.number))"
        }
        if let waiting = progress.waiting, waiting > 0 {
            return "\(waiting.formatted(.number)) waiting"
        }
        return nil
    }

    /// The Progress column / popover second line of an active operation: the reason it waits,
    /// or the item in flight with its facts.
    static func activeLine(_ operation: ActivityOperation) -> String? {
        if let wait = operation.wait, operation.state != .running {
            var parts = [wait.sentence]
            if let waiting = operation.progress.waiting, waiting > 0 {
                parts.append("\(waiting.formatted(.number)) waiting")
            } else if let total = operation.progress.total, total > 0 {
                parts.append(operation.itemNoun.counted(total))
            }
            return parts.joined(separator: " · ")
        }
        var parts: [String] = []
        if let item = operation.progress.currentItem, !item.isEmpty { parts.append(item) }
        if let detail = operation.progress.detail, !detail.isEmpty { parts.append(detail) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The Result column / Recent line (`35 downloaded · 9 failed`, the cause of a failure).
    static func resultText(_ operation: ActivityOperation) -> String? {
        guard let result = operation.result else { return nil }
        if operation.state == .failed, let cause = result.failureCause { return cause }
        let sentence = result.sentence
        return sentence.isEmpty ? nil : sentence
    }

    // MARK: - Status bar (UC-JOB-08, UC-STATUS-05)

    /// `Download started — 44 tracks` · `Sync started — “iPod Classic”`.
    static func startMessage(_ operation: ActivityOperation) -> String {
        if let total = operation.progress.total, total > 0 {
            return "\(operation.messageName) started — \(operation.itemNoun.counted(total))"
        }
        if let name = operation.subject.name, operation.subject.kind != .none {
            return "\(operation.messageName) started — “\(name)”"
        }
        return "\(operation.messageName) started"
    }

    /// `Import finished — 35 downloaded, 9 failed` · `Backup failed — ‹cause›` ·
    /// `Download cancelled — 12 downloaded`.
    static func endMessage(_ operation: ActivityOperation) -> String {
        let name = operation.messageName
        let result = operation.result ?? .empty
        switch operation.state {
        case .failed:
            return "\(name) failed — \(result.failureCause ?? "the details are in Activity")"
        case .cancelled:
            let sentence = result.statusSentence
            return sentence.isEmpty ? "\(name) cancelled" : "\(name) cancelled — \(sentence)"
        default:
            let sentence = result.statusSentence
            return sentence.isEmpty ? "\(name) finished" : "\(name) finished — \(sentence)"
        }
    }

    // MARK: - Toolbar item (UC-JOB-04, §23 C14)

    struct ToolbarSummary: Equatable {
        /// `Downloading 12 of 44 +2` (oldest running operation + the number of others).
        var runningText: String?
        /// Ring value; `nil` = indeterminate spinner (only while something runs).
        var fraction: Double?
        var isRunning: Bool
        /// `14 waiting for “Lexxar”`.
        var waitingText: String?
        /// `9 failed` — stays until dismissed or fixed.
        var failedText: String?

        /// The words for VoiceOver and the help tag (UC-A11Y-03): `Downloading 12 of 44, 9 failed`.
        var sentence: String {
            let parts = [runningText, waitingText, failedText].compactMap { $0 }
            return parts.isEmpty ? "No activity" : parts.joined(separator: ", ")
        }

        var isIdle: Bool { runningText == nil && waitingText == nil && failedText == nil }

        static let idle = ToolbarSummary(runningText: nil, fraction: nil, isRunning: false, waitingText: nil, failedText: nil)
    }

    /// The toolbar item's state from the center's operations.
    @MainActor
    static func toolbarSummary(_ center: ActivityCenter) -> ToolbarSummary {
        let active = center.activeOperations.filter { !center.isQuiet($0.id) }
        let running = active.filter { $0.state == .running }
        var summary = ToolbarSummary.idle
        if let oldest = running.first {
            let others = active.count - 1
            var text: String
            if let progress = progressText(oldest.progress) {
                text = oldest.progress.isDeterminate
                    ? "\(verb(for: oldest)) \(progress)"
                    : "\(verb(for: oldest)) · \(progress)"
            } else {
                text = "\(verb(for: oldest))…"
            }
            if others > 0 { text += " +\(others)" }
            summary.runningText = text
            summary.fraction = oldest.progress.fraction
            summary.isRunning = true
        }
        let waiting = driveWaiting(center)
        if let first = waiting.first {
            summary.waitingText = "\(first.count.formatted(.number)) waiting for “\(first.volume)”"
        }
        let failed = failedCount(center)
        if failed > 0 { summary.failedText = "\(failed.formatted(.number)) failed" }
        return summary
    }

    /// Everything the toolbar's `‹n› failed` counts: per undismissed attention operation its
    /// failed tracks that still fail (each track once), plus 1 for each other failure.
    @MainActor
    static func failedCount(_ center: ActivityCenter) -> Int {
        attentionGroups(center).filter { !$0.isWaiting }.reduce(0) { $0 + $1.count }
    }

    // MARK: - Needs attention (UC-JOB-05, UC-JOB-11)

    struct AttentionGroup: Identifiable, Equatable {
        let id: String
        /// `9 downloads failed — sign-in expired (SoundCloud)` · `“Lexxar” not connected · 14 waiting`.
        let headline: String
        let count: Int
        let fix: ActivityFix?
        let note: String?
        let operationIDs: [UUID]
        let trackIDs: [Int64]
        let isWaiting: Bool
        let isRetryable: Bool
        /// Where it came from: the newest operation (`From “Dekmantel 2024”`) and its end.
        let originTitle: String?
        let originSubject: ActivitySubject?
        let originDate: Date?
    }

    struct DriveWait: Equatable {
        let volume: String
        let count: Int
        let operationIDs: [UUID]
        let note: String
    }

    /// Active operations that wait for a drive, by volume (`“Lexxar” not connected · 14 waiting`).
    @MainActor
    static func driveWaiting(_ center: ActivityCenter) -> [DriveWait] {
        var order: [String] = []
        var byVolume: [String: [ActivityOperation]] = [:]
        for op in center.activeOperations {
            guard case .drive(let volume) = op.wait else { continue }
            if byVolume[volume] == nil { order.append(volume) }
            byVolume[volume, default: []].append(op)
        }
        return order.map { volume in
            let ops = byVolume[volume] ?? []
            var perNoun: [(ActivityNoun, Int)] = []
            var total = 0
            for op in ops {
                let n = waitingItems(op)
                total += n
                if let index = perNoun.firstIndex(where: { $0.0 == op.itemNoun }) {
                    perNoun[index].1 += n
                } else {
                    perNoun.append((op.itemNoun, n))
                }
            }
            let list = perNoun.map { $0.0.counted($0.1) }.joined(separator: " and ")
            return DriveWait(volume: volume, count: total, operationIDs: ops.map(\.id),
                             note: "\(list) resume when the drive is connected.")
        }
    }

    /// Items an active operation still has to do.
    static func waitingItems(_ op: ActivityOperation) -> Int {
        if let waiting = op.progress.waiting, waiting > 0 { return waiting }
        if let total = op.progress.total, total > 0 { return max(total - op.progress.completed, 1) }
        return 1
    }

    /// Needs attention, grouped by cause across operations (largest first), drive waits first.
    @MainActor
    static func attentionGroups(_ center: ActivityCenter) -> [AttentionGroup] {
        var groups: [AttentionGroup] = driveWaiting(center).map { wait in
            AttentionGroup(
                id: "drive:\(wait.volume)",
                headline: "“\(wait.volume)” not connected · \(wait.count.formatted(.number)) waiting",
                count: wait.count, fix: .waitForDrive, note: wait.note, operationIDs: wait.operationIDs,
                trackIDs: [], isWaiting: true, isRetryable: false, originTitle: nil, originSubject: nil,
                originDate: nil)
        }

        struct Bucket {
            var cause: String
            var fix: ActivityFix?
            var note: String?
            var retryable: Bool
            var ops: [ActivityOperation] = []
            var tracks: [Int64] = []
            var seen: Set<Int64> = []
            var otherCount = 0
            var isDownload: Bool
        }
        var order: [String] = []
        var buckets: [String: Bucket] = [:]
        // Newest first, so a track failing in two batches counts once, for the newest.
        let attention = center.finishedOperations.filter { $0.needsAttention && $0.dismissedAt == nil }
        for op in attention {
            let result = op.result ?? .empty
            let live = center.stillFailing(op)
            for group in result.failureGroups {
                let isTrackGroup = !group.trackIDs.isEmpty
                let tracks = isTrackGroup ? group.trackIDs.filter { live.contains($0) } : []
                if isTrackGroup && tracks.isEmpty { continue }
                let key = "\(isTrackGroup ? "tracks" : op.kind.rawValue):\(group.cause)"
                if buckets[key] == nil {
                    order.append(key)
                    buckets[key] = Bucket(cause: group.cause, fix: group.fix, note: group.note,
                                          retryable: group.isRetryable, isDownload: isTrackGroup)
                }
                buckets[key]?.ops.append(op)
                if isTrackGroup {
                    for id in tracks where !(buckets[key]?.seen.contains(id) ?? true) {
                        buckets[key]?.seen.insert(id)
                        buckets[key]?.tracks.append(id)
                    }
                } else {
                    buckets[key]?.otherCount += max(group.count, 1)
                }
            }
        }
        var failureGroups: [AttentionGroup] = order.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            let newest = bucket.ops.first
            let count = bucket.isDownload ? bucket.tracks.count : bucket.otherCount
            guard count > 0 else { return nil }
            let headline: String
            if bucket.isDownload {
                headline = ActivityFailureGrouping.headline(for: ActivityFailureGroup(cause: bucket.cause, count: count))
            } else if let newest {
                if bucket.ops.count > 1 {
                    headline = "\(bucket.ops.count.formatted(.number)) operations failed — \(bucket.cause)"
                } else if count > 1 {
                    headline = "\(count.formatted(.number)) failed in \(newest.title) — \(bucket.cause)"
                } else {
                    headline = "\(newest.title) failed — \(bucket.cause)"
                }
            } else {
                headline = bucket.cause
            }
            return AttentionGroup(
                id: key, headline: headline, count: count, fix: bucket.fix, note: bucket.note,
                operationIDs: bucket.ops.map(\.id), trackIDs: bucket.tracks, isWaiting: false,
                isRetryable: bucket.retryable, originTitle: newest?.subject.name ?? newest?.title,
                originSubject: newest?.subject, originDate: newest?.endedAt)
        }
        failureGroups.sort { $0.count > $1.count }
        groups.append(contentsOf: failureGroups)
        return groups
    }

    // MARK: - Times (UC-COPY-10)

    /// `21:40` today, `Yesterday`, `3 Oct` before — the Recent column.
    static func shortTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// `Today 21:40` / `4 Oct 2026, 08:57` — the Started column.
    static func startedText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// `52 s`, `4 min`, `1 h 12 min`.
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min" }
        return "\(total / 3600) h \((total % 3600) / 60) min"
    }

    /// `Copy Summary` (CM-OPS-ROW): the operation in plain text for a bug report.
    static func summaryText(_ operation: ActivityOperation) -> String {
        var lines = ["\(operation.title) — \(operation.state.word)"]
        if let link = operation.subject.linkLabel { lines.append("Subject: \(link)") }
        lines.append("Started: \(operation.startedAt.formatted(date: .abbreviated, time: .standard))")
        if let end = operation.endedAt {
            lines.append("Ended: \(end.formatted(date: .abbreviated, time: .standard))")
        }
        if let result = resultText(operation) { lines.append("Result: \(result)") }
        for group in operation.result?.failureGroups ?? [] {
            lines.append("· \(group.count.formatted(.number)) — \(group.cause)")
        }
        return lines.joined(separator: "\n")
    }
}
