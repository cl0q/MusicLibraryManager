import Foundation

// MARK: - Row status

enum ActivityRowStatus: String, Equatable {
    case running, completed, failed, cancelled, stalled
}

// MARK: - Row actions

enum ActivityRowAction: Equatable {
    case cancel(operationID: UUID)
    case retry(operationID: UUID)
    case retryDownloads(trackIDs: [Int64])
    case pauseSync
    case resumeSync
    case clearAnalysisQueue
    case clearRecent
}

// MARK: - Child item

struct ActivityChildItem: Identifiable, Equatable {
    let id: String
    let title: String
    let statusText: String
    var statusColorName: String
    var errorText: String?
}

// MARK: - Row

struct ActivityRow: Identifiable, Equatable {
    let id: String
    let kind: ActivityViewModel.Operation.OperationType
    let status: ActivityRowStatus
    let title: String
    let detail: String
    let progress: Double?
    let percentText: String?
    let badgeText: String?
    let durationText: String?
    let timestampText: String?
    let actions: [ActivityRowAction]
    let childItems: [ActivityChildItem]
    let isStalled: Bool
    let attention: Bool
    let accessibilityIdentifier: String
}

// MARK: - Section

enum ActivitySectionKind: String, CaseIterable, Equatable {
    case active, attention, recent
}

struct ActivitySection: Identifiable, Equatable {
    let kind: ActivitySectionKind
    let title: String
    let rows: [ActivityRow]
    let headerActions: [ActivityRowAction]
    let showsCapNotice: Bool
    var id: String { kind.rawValue }
}

// MARK: - Headline

struct ActivityHeadline: Equatable {
    let text: String
    let tooltip: String
    let isBusy: Bool
    let isEmpty: Bool
}

// MARK: - Snapshot

struct ActivityFeedSnapshot: Equatable {
    let sections: [ActivitySection]
    let headline: ActivityHeadline
    let isEmpty: Bool
}

// MARK: - Input value types

struct DownloadSourceState: Equatable {
    var isDownloading: Bool
    var completedCount: Int
    var failedCount: Int
    var totalCount: Int
    var progress: Double
    var currentTrack: String
    var skippedCount: Int
    var cancelledCount: Int
    var hasActionableRetryFailures: Bool
    var queueItems: [ActivityChildItem]
    var operationID: UUID?
}

struct SyncSourceState: Equatable {
    var isSyncing: Bool
    var isPaused: Bool
    var processed: Int
    var total: Int
    var progress: Double
    var currentFile: String
    var syncedCount: Int?
    var failedCount: Int?
    var operationID: UUID?
}

struct QueueSourceState: Equatable {
    var activeJobDescription: String?
    var pendingAnalyses: Int
    var pendingDownloads: Int
}

struct PersistedFailureInput: Equatable {
    let trackID: Int64
    let artist: String
    let title: String
    let reason: String
    let date: Date
    let attempts: Int
}

// MARK: - Pure aggregation

enum ActivityFeed {

    static func makeSnapshot(
        operations: [ActivityViewModel.Operation],
        stalledIDs: Set<UUID>,
        recentOperations: [ActivityViewModel.Operation],
        recentTruncated: Bool,
        download: DownloadSourceState?,
        sync: SyncSourceState?,
        queue: QueueSourceState?,
        persistedFailures: [PersistedFailureInput],
        now: Date
    ) -> ActivityFeedSnapshot {

        // MARK: Active rows

        var activeRows: [ActivityRow] = []

        // Running operations from the VM — no .sync filtering (behavior 2).
        let runningOps = operations
            .filter { $0.status == .running }
            .sorted { $0.startedAt < $1.startedAt }

        for op in runningOps {
            activeRows.append(rowForOperation(op, stalledIDs: stalledIDs, now: now))
        }

        // Non-running operations still in the active list → attention.
        let terminalInActive = operations.filter { $0.status != .running }

        // Download batch row from source state.
        if let dl = download, dl.isDownloading {
            activeRows.append(rowForDownloadSource(dl, now: now))
        }

        // Sync batch row from source state.
        if let sy = sync, sy.isSyncing {
            activeRows.append(rowForSyncSource(sy, now: now))
        }

        // Queue row from source state.
        if let q = queue, hasQueueWork(q) {
            activeRows.append(rowForQueueSource(q, now: now))
        }

        // MARK: Attention rows

        var attentionRows: [ActivityRow] = []

        // Failed/cancelled ops still in the active list.
        let coveredTrackIDs = Set(terminalInActive.flatMap(\.retryTrackIds))

        for op in terminalInActive.sorted(by: { ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt) }) {
            attentionRows.append(rowForFailedOperation(op, now: now))
        }

        // Persisted failures — deduplicated against covered track IDs.
        for pf in persistedFailures.sorted(by: { $0.date > $1.date }) {
            if coveredTrackIDs.contains(pf.trackID) { continue }
            attentionRows.append(rowForPersistedFailure(pf, now: now))
        }

        // MARK: Recent rows

        let recentRows = recentOperations
            .sorted { ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt) }
            .map { rowForRecentOperation($0, now: now) }

        // MARK: Sections

        var sections: [ActivitySection] = []

        if !activeRows.isEmpty {
            sections.append(ActivitySection(
                kind: .active,
                title: "Active",
                rows: activeRows,
                headerActions: [],
                showsCapNotice: false
            ))
        }

        if !attentionRows.isEmpty {
            sections.append(ActivitySection(
                kind: .attention,
                title: "Needs Attention",
                rows: attentionRows,
                headerActions: [],
                showsCapNotice: false
            ))
        }

        if !recentRows.isEmpty {
            var recentHeaderActions: [ActivityRowAction] = []
            recentHeaderActions.append(.clearRecent)
            sections.append(ActivitySection(
                kind: .recent,
                title: "Recent",
                rows: recentRows,
                headerActions: recentHeaderActions,
                showsCapNotice: recentTruncated
            ))
        }

        // MARK: Headline

        let headline = buildHeadline(activeRows: activeRows)

        let isEmpty = sections.allSatisfy { $0.rows.isEmpty }

        return ActivityFeedSnapshot(
            sections: sections,
            headline: headline,
            isEmpty: isEmpty
        )
    }

    // MARK: - Headline

    static func headlineSegments(
        download: String?,
        sync: String?,
        queue: String?,
        others: [String]
    ) -> [String] {
        var segments: [String] = []
        if let download, !download.isEmpty { segments.append(download) }
        if let sync, !sync.isEmpty { segments.append(sync) }
        segments.append(contentsOf: others.filter { !$0.isEmpty })
        if let queue, !queue.isEmpty { segments.append(queue) }
        return segments
    }

    private static func buildHeadline(activeRows: [ActivityRow]) -> ActivityHeadline {
        guard !activeRows.isEmpty else {
            return ActivityHeadline(
                text: "No active operations",
                tooltip: "No active operations",
                isBusy: false,
                isEmpty: true
            )
        }

        var downloadSegment: String?
        var syncSegment: String?
        var queueSegment: String?
        var otherSegments: [String] = []

        for row in activeRows {
            switch row.kind {
            case .download:
                if downloadSegment == nil { downloadSegment = row.title }
            case .sync:
                if syncSegment == nil { syncSegment = row.title }
            case .analysis:
                if queueSegment == nil { queueSegment = row.title }
            default:
                otherSegments.append(row.title)
            }
        }

        let segments = headlineSegments(
            download: downloadSegment,
            sync: syncSegment,
            queue: queueSegment,
            others: otherSegments
        )

        let fullText = segments.joined(separator: " \u{00B7} ")

        return ActivityHeadline(
            text: fullText,
            tooltip: fullText,
            isBusy: true,
            isEmpty: false
        )
    }

    // MARK: - Batch counter

    static func batchCounter(completed: Int, total: Int, isRunning: Bool) -> String? {
        if isRunning {
            if total == 0 && completed == 0 { return nil }
            let numerator = min(completed + 1, total)
            return "\(numerator) / \(total)"
        } else {
            return "\(completed) / \(total)"
        }
    }

    // MARK: - Row builders

    private static func rowForOperation(
        _ op: ActivityViewModel.Operation,
        stalledIDs: Set<UUID>,
        now: Date
    ) -> ActivityRow {
        let isStalled = stalledIDs.contains(op.id)
        let status: ActivityRowStatus = isStalled ? .stalled : .running

        var actions: [ActivityRowAction] = []
        if op.isCancellable {
            actions.append(.cancel(operationID: op.id))
        }

        let percentText = "\(Int((op.progress * 100).rounded()))%"
        let identifier = "operation_row_" + op.type.rawValue

        return ActivityRow(
            id: op.id.uuidString,
            kind: op.type,
            status: status,
            title: op.title,
            detail: op.detail,
            progress: op.progress,
            percentText: percentText,
            badgeText: isStalled ? "Stalled" : nil,
            durationText: formatDuration(op.startedAt, now: now),
            timestampText: formatTimestamp(op.startedAt, now: now),
            actions: actions,
            childItems: [],
            isStalled: isStalled,
            attention: false,
            accessibilityIdentifier: identifier
        )
    }

    private static func rowForFailedOperation(
        _ op: ActivityViewModel.Operation,
        now: Date
    ) -> ActivityRow {
        let status: ActivityRowStatus
        switch op.status {
        case .failed: status = .failed
        case .cancelled: status = .cancelled
        default: status = .failed
        }

        var actions: [ActivityRowAction] = []
        if op.type == .download {
            actions.append(.retryDownloads(trackIDs: op.retryTrackIds))
        } else if op.isRetryable {
            actions.append(.retry(operationID: op.id))
        }

        let badgeText: String
        switch op.status {
        case .failed: badgeText = "Failed"
        case .cancelled: badgeText = "Cancelled"
        default: badgeText = "Failed"
        }

        let identifier = "operation_row_" + op.type.rawValue

        return ActivityRow(
            id: op.id.uuidString,
            kind: op.type,
            status: status,
            title: op.title,
            detail: op.detail,
            progress: nil,
            percentText: nil,
            badgeText: badgeText,
            durationText: formatDuration(op.startedAt, now: now),
            timestampText: op.completedAt.map { formatTimestamp($0, now: now) },
            actions: actions,
            childItems: [],
            isStalled: false,
            attention: true,
            accessibilityIdentifier: identifier
        )
    }

    private static func rowForRecentOperation(
        _ op: ActivityViewModel.Operation,
        now: Date
    ) -> ActivityRow {
        let status: ActivityRowStatus
        switch op.status {
        case .completed: status = .completed
        case .failed: status = .failed
        case .cancelled: status = .cancelled
        case .running: status = .completed
        }

        var actions: [ActivityRowAction] = []
        if op.status == .failed {
            if op.type == .download {
                actions.append(.retryDownloads(trackIDs: op.retryTrackIds))
            } else if op.isRetryable {
                actions.append(.retry(operationID: op.id))
            }
        }

        let badgeText: String?
        switch op.status {
        case .failed: badgeText = "Failed"
        case .cancelled: badgeText = "Cancelled"
        default: badgeText = nil
        }

        let identifier = "operation_row_" + op.type.rawValue

        return ActivityRow(
            id: op.id.uuidString,
            kind: op.type,
            status: status,
            title: op.title,
            detail: op.detail,
            progress: nil,
            percentText: nil,
            badgeText: badgeText,
            durationText: formatDuration(op.startedAt, now: now),
            timestampText: op.completedAt.map { formatTimestamp($0, now: now) },
            actions: actions,
            childItems: [],
            isStalled: false,
            attention: op.status == .failed,
            accessibilityIdentifier: identifier
        )
    }

    private static func rowForDownloadSource(
        _ dl: DownloadSourceState,
        now: Date
    ) -> ActivityRow {
        var actions: [ActivityRowAction] = []
        if let opID = dl.operationID {
            actions.append(.cancel(operationID: opID))
        }

        let counter = batchCounter(
            completed: dl.completedCount,
            total: dl.totalCount,
            isRunning: dl.isDownloading
        )

        let title = dl.currentTrack.isEmpty
            ? "Downloading…"
            : dl.currentTrack

        let detail: String
        if dl.totalCount > 0 {
            detail = counter ?? "Downloading…"
        } else {
            detail = "Downloading…"
        }

        let percentText: String?
        if dl.totalCount > 0 {
            percentText = counter
        } else {
            percentText = nil
        }

        let identifier = "operation_row_" + ActivityViewModel.Operation.OperationType.download.rawValue

        return ActivityRow(
            id: dl.operationID?.uuidString ?? "download_batch",
            kind: .download,
            status: .running,
            title: title,
            detail: detail,
            progress: dl.progress > 0 ? dl.progress : nil,
            percentText: percentText,
            badgeText: nil,
            durationText: nil,
            timestampText: nil,
            actions: actions,
            childItems: dl.queueItems,
            isStalled: false,
            attention: false,
            accessibilityIdentifier: identifier
        )
    }

    private static func rowForSyncSource(
        _ sy: SyncSourceState,
        now: Date
    ) -> ActivityRow {
        var actions: [ActivityRowAction] = []

        if let opID = sy.operationID {
            actions.append(.cancel(operationID: opID))
        }

        if sy.isPaused {
            actions.append(.resumeSync)
        } else {
            actions.append(.pauseSync)
        }

        let title = sy.currentFile.isEmpty
            ? "Syncing…"
            : sy.currentFile

        let counter = batchCounter(
            completed: sy.processed,
            total: sy.total,
            isRunning: sy.isSyncing
        )

        let identifier = "operation_row_" + ActivityViewModel.Operation.OperationType.sync.rawValue

        return ActivityRow(
            id: sy.operationID?.uuidString ?? "sync_batch",
            kind: .sync,
            status: .running,
            title: title,
            detail: counter ?? "Syncing…",
            progress: sy.progress > 0 ? sy.progress : nil,
            percentText: counter,
            badgeText: sy.isPaused ? "Paused" : nil,
            durationText: nil,
            timestampText: nil,
            actions: actions,
            childItems: [],
            isStalled: false,
            attention: false,
            accessibilityIdentifier: identifier
        )
    }

    private static func rowForQueueSource(
        _ q: QueueSourceState,
        now: Date
    ) -> ActivityRow {
        let totalPending = q.pendingAnalyses + q.pendingDownloads

        var actions: [ActivityRowAction] = []
        if totalPending > 0 {
            actions.append(.clearAnalysisQueue)
        }

        let title = q.activeJobDescription ?? "\(q.pendingAnalyses) analyses pending"

        let identifier = "operation_row_" + ActivityViewModel.Operation.OperationType.analysis.rawValue

        return ActivityRow(
            id: "analysis_queue",
            kind: .analysis,
            status: .running,
            title: title,
            detail: "\(totalPending) items pending",
            progress: nil,
            percentText: nil,
            badgeText: nil,
            durationText: nil,
            timestampText: nil,
            actions: actions,
            childItems: [],
            isStalled: false,
            attention: false,
            accessibilityIdentifier: identifier
        )
    }

    private static func rowForPersistedFailure(
        _ pf: PersistedFailureInput,
        now: Date
    ) -> ActivityRow {
        let identifier = "operation_row_download_persisted"

        return ActivityRow(
            id: "persisted_failure_\(pf.trackID)",
            kind: .download,
            status: .failed,
            title: "\(pf.artist) – \(pf.title)",
            detail: pf.reason,
            progress: nil,
            percentText: nil,
            badgeText: "Failed",
            durationText: nil,
            timestampText: formatTimestamp(pf.date, now: now),
            actions: [.retryDownloads(trackIDs: [pf.trackID])],
            childItems: [],
            isStalled: false,
            attention: true,
            accessibilityIdentifier: identifier
        )
    }

    // MARK: - Helpers

    private static func hasQueueWork(_ q: QueueSourceState) -> Bool {
        q.pendingAnalyses > 0 || q.pendingDownloads > 0 || q.activeJobDescription != nil
    }

    private static func formatDuration(_ start: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(start))
        guard seconds >= 0 else { return "0:00" }
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func formatTimestamp(_ date: Date, now: Date) -> String {
        let ago = now.timeIntervalSince(date)
        if ago < 60 { return "just now" }
        if ago < 3600 { return "\(Int(ago / 60))m ago" }
        if ago < 86400 { return "\(Int(ago / 3600))h ago" }
        return "\(Int(ago / 86400))d ago"
    }
}
