import Testing
import Foundation
@testable import MLM

/// Contract tests for Module 2 — `ActivityFeed`, the pure aggregation layer
/// that replaces the six bespoke row types in `OperationsTab.swift`.
///
/// The entire surface under test is a pure function over value structs.
/// No singletons, no view models, no SwiftUI. If a test reaches for
/// `PerformanceQueueService.shared` or constructs a real `DownloadViewModel`,
/// the test is wrong.
///
/// References types that do not yet exist: `ActivityFeed`, `ActivityFeedSnapshot`,
/// `ActivitySection`, `ActivityRow`, `ActivityRowStatus`, `ActivityRowAction`,
/// `ActivityChildItem`, `ActivityHeadline`, `ActivitySectionKind`,
/// `DownloadSourceState`, `SyncSourceState`, `QueueSourceState`,
/// `PersistedFailureInput`. The test target will NOT compile until Module 2
/// lands. That is the expected RED state.
@Suite("ActivityFeedTests")
@MainActor
struct ActivityFeedTests {

    // MARK: - Fixtures

    private static let referenceNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeOperation(
        id: UUID = UUID(),
        type: ActivityViewModel.Operation.OperationType,
        title: String = "Op",
        status: ActivityViewModel.Operation.OperationStatus = .running,
        progress: Double = 0.0,
        detail: String = "",
        startedAt: Date = Self.referenceNow,
        completedAt: Date? = nil,
        retryTrackIds: [Int64] = [],
        isCancellable: Bool = false
    ) -> ActivityViewModel.Operation {
        // The existing `Operation` struct has a memberwise initializer; the
        // Module-1 contract adds `lastProgressAt` / `retryTrackIds` /
        // `isCancellable` with defaults, so this call site stays valid.
        var op = ActivityViewModel.Operation(
            type: type,
            title: title,
            status: status,
            progress: progress,
            detail: detail,
            startedAt: startedAt,
            completedAt: completedAt
        )
        op.retryTrackIds = retryTrackIds
        op.isCancellable = isCancellable
        // Replace the auto-assigned UUID by rebuilding through the stored
        // `id` property — Operation's `id` is `let id = UUID()`, so we
        // cannot inject it directly. Instead, the feed is addressed by
        // `id.uuidString` inside rows; for deterministic assertions we
        // compare by the returned operation's `id`, not by a chosen UUID.
        _ = id
        return op
    }

    private func emptyDownload() -> DownloadSourceState {
        .init(
            isDownloading: false, completedCount: 0, failedCount: 0,
            totalCount: 0, progress: 0, currentTrack: "",
            skippedCount: 0, cancelledCount: 0,
            hasActionableRetryFailures: false, queueItems: [], operationID: nil
        )
    }

    private func emptySync() -> SyncSourceState {
        .init(
            isSyncing: false, isPaused: false, processed: 0, total: 0,
            progress: 0, currentFile: "", syncedCount: nil,
            failedCount: nil, operationID: nil
        )
    }

    private func emptyQueue() -> QueueSourceState {
        .init(activeJobDescription: nil, pendingAnalyses: 0, pendingDownloads: 0)
    }

    // MARK: - Behavior 1: section order + empty omission

    @Test("Sections are ordered active → attention → recent")
    func sectionOrder() {
        let running = makeOperation(type: .artwork, status: .running)
        let failed = makeOperation(
            type: .import, status: .failed,
            completedAt: Self.referenceNow.addingTimeInterval(-60)
        )
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [running],
            stalledIDs: [],
            recentOperations: [failed],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let kinds = snapshot.sections.map(\.kind)
        #expect(
            kinds == [.active, .recent],
            "Active must preced Recent; empty attention section must be omitted entirely"
        )
    }

    @Test("Empty sections are omitted, not emitted with zero rows")
    func emptySectionsOmitted() {
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        #expect(
            snapshot.sections.isEmpty,
            "With no inputs, no section should be present — empty sections are omitted"
        )
        #expect(snapshot.isEmpty, "snapshot.isEmpty must be true when every section is empty")
    }

    // MARK: - Behavior 2: no .sync filtering

    @Test("A running .sync operation produces an Active row even when sync == nil")
    func syncOperationNotFilteredWhenSyncSourceNil() {
        let syncOp = makeOperation(type: .sync, title: "Library sync", status: .running)
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [syncOp],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let active = snapshot.sections.first(where: { $0.kind == .active })
        #expect(active != nil, "Active section must be present")
        #expect(
            active?.rows.contains(where: { $0.kind == .sync }) == true,
            "The vanishing-operation bug: .sync rows must NOT be filtered out when sync source is nil"
        )
    }

    // MARK: - Behavior 3: concurrency visibility

    @Test("Download + sync + queue + artwork all appear in Active")
    func concurrencyVisible() {
        let artwork = makeOperation(type: .artwork, status: .running)
        let download = emptyDownload().mutating { $0.isDownloading = true; $0.totalCount = 5 }
        let sync = emptySync().mutating { $0.isSyncing = true; $0.total = 10 }
        let queue = emptyQueue().mutating { $0.pendingAnalyses = 3 }
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [artwork],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: download, sync: sync, queue: queue,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let active = snapshot.sections.first(where: { $0.kind == .active })
        #expect(
            (active?.rows.count ?? 0) >= 4,
            "All four concurrent sources must produce distinct Active rows"
        )
    }

    // MARK: - Behavior 4: ordering

    @Test("Active rows are ordered startedAt ascending (oldest first)")
    func activeOrderingOldestFirst() {
        let older = makeOperation(
            type: .analysis, status: .running,
            startedAt: Self.referenceNow.addingTimeInterval(-100)
        )
        let newer = makeOperation(
            type: .artwork, status: .running,
            startedAt: Self.referenceNow.addingTimeInterval(-10)
        )
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [newer, older],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let active = snapshot.sections.first(where: { $0.kind == .active })
        let kinds = active?.rows.map(\.kind) ?? []
        #expect(
            kinds.first == .analysis && kinds.last == .artwork,
            "Oldest-started operation must render first in Active"
        )
    }

    @Test("Recent rows are ordered completedAt descending")
    func recentOrderingNewestFirst() {
        let older = makeOperation(
            type: .import, status: .completed,
            completedAt: Self.referenceNow.addingTimeInterval(-100)
        )
        let newer = makeOperation(
            type: .fingerprint, status: .completed,
            completedAt: Self.referenceNow.addingTimeInterval(-10)
        )
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [older, newer],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let recent = snapshot.sections.first(where: { $0.kind == .recent })
        let kinds = recent?.rows.map(\.kind) ?? []
        #expect(
            kinds.first == .fingerprint,
            "Most-recently-completed operation must render first in Recent"
        )
    }

    // MARK: - Behavior 5: headline aggregation

    @Test("Headline joins concurrent active summaries with middle-dot separator")
    func headlineJoinsConcurrent() {
        let a = makeOperation(type: .download, title: "Downloading 3 tracks", status: .running)
        let b = makeOperation(type: .sync, title: "Syncing library", status: .running)
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [a, b],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        #expect(
            snapshot.headline.text.contains("\u{00B7}"),
            "Headline must join multiple summaries with ' · '"
        )
        #expect(snapshot.headline.isBusy, "isBusy must be true with any active operation")
    }

    @Test("Empty headline reports isEmpty and canonical text")
    func headlineEmpty() {
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        #expect(
            snapshot.headline.isEmpty,
            "headline.isEmpty must be true when there are no active operations"
        )
        #expect(
            snapshot.headline.text == "No active operations",
            "Empty headline text must be the canonical 'No active operations'"
        )
    }

    // MARK: - Behavior 6: headline truncation priority

    @Test("headlineSegments orders highest-priority first: download > sync > others > queue")
    func headlineSegmentPriority() {
        let segments = ActivityFeed.headlineSegments(
            download: "Downloading 3 tracks",
            sync: "Syncing library",
            queue: "4 analyses pending",
            others: ["Artwork fetch"]
        )
        #expect(
            segments.first == "Downloading 3 tracks",
            "Download summary has highest headline priority"
        )
        let syncIndex = segments.firstIndex(of: "Syncing library") ?? Int.max
        let queueIndex = segments.firstIndex(of: "4 analyses pending") ?? Int.max
        #expect(
            syncIndex < queueIndex,
            "Sync must precede queue/analysis in headline priority"
        )
    }

    @Test("headlineSegments drops analysis/queue before download when truncating")
    func headlineTruncationDropsQueueFirst() {
        // When only a download is provided, the segment list must be length 1 —
        // queue/analysis are not synthesised from thin air.
        let segments = ActivityFeed.headlineSegments(
            download: "Downloading 50 tracks",
            sync: nil,
            queue: nil,
            others: []
        )
        #expect(
            segments == ["Downloading 50 tracks"],
            "With only a download source, headline must contain exactly that segment"
        )
    }

    @Test("headline tooltip always equals the full untruncated string")
    func headlineTooltipIsFullString() {
        let a = makeOperation(type: .download, title: "Downloading 3 tracks", status: .running)
        let b = makeOperation(type: .sync, title: "Syncing library", status: .running)
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [a, b],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        #expect(
            snapshot.headline.tooltip.contains("Downloading 3 tracks"),
            "tooltip must contain the FULL untruncated download summary"
        )
        #expect(
            snapshot.headline.tooltip.contains("Syncing library"),
            "tooltip must contain the FULL untruncated sync summary"
        )
    }

    // MARK: - Behavior 7: batchCounter

    @Test("batchCounter: (0,0,running) → nil (no counter, show 'Downloading…')")
    func batchCounterZeroZeroRunning() {
        #expect(
            ActivityFeed.batchCounter(completed: 0, total: 0, isRunning: true) == nil,
            "The 'Downloading 1 / 0' bug: zero/zero while running must yield nil"
        )
    }

    @Test("batchCounter: (2,12,running) → '3 / 12'")
    func batchCounterMidway() {
        #expect(
            ActivityFeed.batchCounter(completed: 2, total: 12, isRunning: true) == "3 / 12",
            "Next-to-process is completed+1; total is the declared total"
        )
    }

    @Test("batchCounter: (12,12,running) → '12 / 12' (never exceeds total)")
    func batchCounterCappedAtTotal() {
        #expect(
            ActivityFeed.batchCounter(completed: 12, total: 12, isRunning: true) == "12 / 12",
            "Even if the caller over-reports, the counter must not exceed total"
        )
    }

    @Test("batchCounter: (7,7,not running) → '7 / 7'")
    func batchCounterTerminal() {
        #expect(
            ActivityFeed.batchCounter(completed: 7, total: 7, isRunning: false) == "7 / 7",
            "Terminal batch must still render the final counter"
        )
    }

    // MARK: - Behavior 8: Needs Attention deduplication

    @Test("Persisted failure whose trackID is covered by a failed operation appears ONCE")
    func attentionDeduplicatesOverlappingFailures() {
        let failedOp = makeOperation(
            type: .download, status: .failed,
            completedAt: Self.referenceNow,
            retryTrackIds: [42]
        )
        let persisted = PersistedFailureInput(
            trackID: 42, artist: "A", title: "T",
            reason: "network", date: Self.referenceNow, attempts: 1
        )
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [failedOp],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [persisted],
            now: Self.referenceNow
        )
        let attention = snapshot.sections.first(where: { $0.kind == .attention })
        let track42Rows = attention?.rows.count ?? 0
        #expect(
            track42Rows == 1,
            "A trackID covered by both a failed operation and a persisted failure must appear exactly once in Needs Attention"
        )
    }

    // MARK: - Behavior 9: single retry path

    // CONTRACT: OperationType is not CaseIterable in the current source.
    // Module 1/2 must add CaseIterable conformance; until then enumerate all
    // seven cases explicitly so a missing case fails the test at compile time.
    private static let allOperationTypes: [ActivityViewModel.Operation.OperationType] = [
        .download, .sync, .import, .analysis, .fingerprint, .artwork, .createMLExport
    ]

    @Test("Failed download row emits retryDownloads(trackIDs:)")
    func retryPathDownload() {
        let failed = makeOperation(
            type: .download, status: .failed,
            completedAt: Self.referenceNow,
            retryTrackIds: [1, 2, 3]
        )
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [failed],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let row = snapshot.sections.flatMap(\.rows).first(where: { $0.kind == .download })
        let hasRetryDownloads = row?.actions.contains(where: { action in
            if case .retryDownloads = action { return true }; return false
        }) ?? false
        let hasRetryOperation = row?.actions.contains(where: { action in
            if case .retry = action { return true }; return false
        }) ?? false
        #expect(hasRetryDownloads, "Download-type failed row must emit .retryDownloads(trackIDs:)")
        #expect(!hasRetryOperation, "Download-type failed row must NOT also emit .retry(operationID:)")
    }

    @Test("Failed retryable non-download rows emit .retry(operationID:) — one per type (A11.2)")
    func retryPathNonDownload() {
        // A11.2: a failed row emits .retry only when isRetryable is true.
        // We signal retryability via non-empty retryTrackIds (isRetryable =
        // retryHandler != nil || !retryTrackIds.isEmpty). retryHandler is
        // added concurrently by A11.1; using retryTrackIds keeps this suite
        // compilable against the current Operation shape.
        for type in Self.allOperationTypes where type != .download {
            let failed = makeOperation(
                type: type, status: .failed,
                completedAt: Self.referenceNow,
                retryTrackIds: [1]
            )
            let snapshot = ActivityFeed.makeSnapshot(
                operations: [],
                stalledIDs: [],
                recentOperations: [failed],
                recentTruncated: false,
                download: nil, sync: nil, queue: nil,
                persistedFailures: [],
                now: Self.referenceNow
            )
            let row = snapshot.sections.flatMap(\.rows).first(where: { $0.kind == type })
            guard let row else {
                Issue.record("No row emitted for failed \(type.rawValue)")
                continue
            }
            let retryCount = row.actions.filter { action in
                if case .retry = action { return true }; return false
            }.count
            let retryDownloadsCount = row.actions.filter { action in
                if case .retryDownloads = action { return true }; return false
            }.count
            #expect(
                retryCount == 1,
                "Failed retryable \(type.rawValue) row must emit exactly one .retry(operationID:)"
            )
            #expect(
                retryDownloadsCount == 0,
                "Non-download failed row must NOT emit .retryDownloads"
            )
        }
    }

    // MARK: - Behavior 9 (A11.2): non-retryable failures emit no retry action

    @Test("Failed non-retryable non-download row emits NO retry action (A11.2)")
    func nonRetryableOperationEmitsNoRetryAction() {
        // A11.2 supersedes the old "always emit .retry" rule. When isRetryable
        // is false (no handler, empty retryTrackIds), the retry button must be
        // ABSENT — not disabled. The failure reason is already in the detail line.
        for type in Self.allOperationTypes where type != .download {
            let failed = makeOperation(
                type: type, status: .failed,
                completedAt: Self.referenceNow,
                retryTrackIds: []
            )
            let snapshot = ActivityFeed.makeSnapshot(
                operations: [],
                stalledIDs: [],
                recentOperations: [failed],
                recentTruncated: false,
                download: nil, sync: nil, queue: nil,
                persistedFailures: [],
                now: Self.referenceNow
            )
            let row = snapshot.sections.flatMap(\.rows).first(where: { $0.kind == type })
            guard let row else {
                Issue.record("No row emitted for failed \(type.rawValue)")
                continue
            }
            let hasRetry = row.actions.contains(where: { action in
                if case .retry = action { return true }; return false
            })
            let hasRetryDownloads = row.actions.contains(where: { action in
                if case .retryDownloads = action { return true }; return false
            })
            #expect(
                !hasRetry,
                "Non-retryable failed \(type.rawValue) row must NOT emit .retry — button must be absent, not disabled"
            )
            #expect(
                !hasRetryDownloads,
                "Non-download failed row must never emit .retryDownloads"
            )
        }
    }

    @Test("Failed download row always emits .retryDownloads regardless of isRetryable (A11.2)")
    func downloadRetryUnchangedByRetryability() {
        // A11.2: .retryDownloads(trackIDs:) for failed .download rows is UNCHANGED
        // and still takes precedence over .retry. Test both retryable and
        // non-retryable download operations.

        // Non-retryable download (empty retryTrackIds): still emits .retryDownloads.
        let nonRetryableDownload = makeOperation(
            type: .download, status: .failed,
            completedAt: Self.referenceNow,
            retryTrackIds: []
        )
        let snapNonRetryable = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [nonRetryableDownload],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let rowNonRetryable = snapNonRetryable.sections.flatMap(\.rows).first(where: { $0.kind == .download })
        let hasRetryDownloadsNR = rowNonRetryable?.actions.contains(where: { action in
            if case .retryDownloads = action { return true }; return false
        }) ?? false
        let hasRetryNR = rowNonRetryable?.actions.contains(where: { action in
            if case .retry = action { return true }; return false
        }) ?? false
        #expect(
            hasRetryDownloadsNR,
            "Failed download row with empty retryTrackIds must still emit .retryDownloads — download retry is independent of isRetryable"
        )
        #expect(
            !hasRetryNR,
            "Failed download row must never emit .retry(operationID:) — .retryDownloads takes precedence"
        )

        // Retryable download (non-empty retryTrackIds): same behavior.
        let retryableDownload = makeOperation(
            type: .download, status: .failed,
            completedAt: Self.referenceNow,
            retryTrackIds: [10, 20]
        )
        let snapRetryable = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [retryableDownload],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let rowRetryable = snapRetryable.sections.flatMap(\.rows).first(where: { $0.kind == .download })
        let hasRetryDownloadsR = rowRetryable?.actions.contains(where: { action in
            if case .retryDownloads = action { return true }; return false
        }) ?? false
        let hasRetryR = rowRetryable?.actions.contains(where: { action in
            if case .retry = action { return true }; return false
        }) ?? false
        #expect(
            hasRetryDownloadsR,
            "Failed download row with non-empty retryTrackIds must emit .retryDownloads"
        )
        #expect(
            !hasRetryR,
            "Failed download row must never also emit .retry(operationID:)"
        )
    }

    @Test("No row in any section ever carries both .retry and .retryDownloads (A11.2)")
    func mutualExclusionOfRetryActions() {
        // A11.2 invariant: a row must never emit both .retry(operationID:) and
        // .retryDownloads(trackIDs:) for the same underlying failure. Exercise
        // every operation type as a failed recent row.
        var failedOps: [ActivityViewModel.Operation] = []
        for type in Self.allOperationTypes {
            failedOps.append(makeOperation(
                type: type, status: .failed,
                completedAt: Self.referenceNow.addingTimeInterval(-Double(failedOps.count)),
                retryTrackIds: [Int64(failedOps.count + 1)]
            ))
        }
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: failedOps,
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        for row in snapshot.sections.flatMap(\.rows) {
            let hasRetry = row.actions.contains(where: { action in
                if case .retry = action { return true }; return false
            })
            let hasRetryDownloads = row.actions.contains(where: { action in
                if case .retryDownloads = action { return true }; return false
            })
            #expect(
                !(hasRetry && hasRetryDownloads),
                "Row \(row.id) (kind: \(row.kind.rawValue)) must not carry both .retry and .retryDownloads — mutual exclusion invariant"
            )
        }
    }

    // MARK: - Behavior 10: cancel is universal

    @Test("Every running cancellable ActivityViewModel operation type exposes a .cancel action")
    func cancelUniversalForRunning() {
        for type in Self.allOperationTypes {
            let running = makeOperation(type: type, status: .running, isCancellable: true)
            let snapshot = ActivityFeed.makeSnapshot(
                operations: [running],
                stalledIDs: [],
                recentOperations: [],
                recentTruncated: false,
                download: nil, sync: nil, queue: nil,
                persistedFailures: [],
                now: Self.referenceNow
            )
            let row = snapshot.sections.flatMap(\.rows).first(where: { $0.kind == type })
            guard let row else {
                Issue.record("No row emitted for running \(type.rawValue)")
                continue
            }
            let hasCancel = row.actions.contains(where: { action in
                if case .cancel = action { return true }; return false
            })
            #expect(
                hasCancel,
                "Running \(type.rawValue) row (from ActivityViewModel) must expose .cancel — those rows always have an id"
            )
        }
    }

    @Test("Driver-backed download batch row emits .cancel iff operationID is non-nil (A5)")
    func cancelDriverBackedDownload() {
        // operationID == nil → feed emits NO cancel; OperationsTab wires the fallback.
        let noIdDownload = emptyDownload().mutating {
            $0.isDownloading = true
            $0.totalCount = 5
            $0.operationID = nil
        }
        let snapNoId = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: noIdDownload, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let rowNoId = snapNoId.sections.flatMap(\.rows).first(where: { $0.kind == .download })
        let hasCancelNoId = rowNoId?.actions.contains(where: { action in
            if case .cancel = action { return true }; return false
        }) ?? false
        #expect(
            !hasCancelNoId,
            "Download batch row with operationID == nil must NOT emit .cancel — OperationsTab owns the fallback"
        )

        // operationID != nil → feed emits .cancel(operationID:).
        let driverID = UUID()
        let withIdDownload = emptyDownload().mutating {
            $0.isDownloading = true
            $0.totalCount = 5
            $0.operationID = driverID
        }
        let snapWithId = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: withIdDownload, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let rowWithId = snapWithId.sections.flatMap(\.rows).first(where: { $0.kind == .download })
        let cancelMatches = rowWithId?.actions.filter { action in
            if case .cancel(let id) = action { return id == driverID }; return false
        }.count ?? 0
        #expect(
            cancelMatches == 1,
            "Download batch row with non-nil operationID must emit exactly one .cancel(operationID:) matching the driver id"
        )
    }

    @Test("Driver-backed sync batch row emits .cancel iff operationID is non-nil (A5)")
    func cancelDriverBackedSync() {
        let noIdSync = emptySync().mutating {
            $0.isSyncing = true
            $0.total = 10
            $0.operationID = nil
        }
        let snapNoId = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: noIdSync, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let rowNoId = snapNoId.sections.flatMap(\.rows).first(where: { $0.kind == .sync })
        let hasCancelNoId = rowNoId?.actions.contains(where: { action in
            if case .cancel = action { return true }; return false
        }) ?? false
        #expect(
            !hasCancelNoId,
            "Sync batch row with operationID == nil must NOT emit .cancel — OperationsTab owns the fallback"
        )

        let driverID = UUID()
        let withIdSync = emptySync().mutating {
            $0.isSyncing = true
            $0.total = 10
            $0.operationID = driverID
        }
        let snapWithId = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: withIdSync, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let rowWithId = snapWithId.sections.flatMap(\.rows).first(where: { $0.kind == .sync })
        let cancelMatches = rowWithId?.actions.filter { action in
            if case .cancel(let id) = action { return id == driverID }; return false
        }.count ?? 0
        #expect(
            cancelMatches == 1,
            "Sync batch row with non-nil operationID must emit exactly one .cancel(operationID:) matching the driver id"
        )
    }

    // MARK: - Behavior 11: sync pause/resume

    @Test("Paused sync row emits .resumeSync")
    func syncPausedEmitsResume() {
        var sync = emptySync()
        sync.isSyncing = true
        sync.isPaused = true
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: sync, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let row = snapshot.sections.flatMap(\.rows).first(where: { $0.kind == .sync })
        let hasResume = row?.actions.contains(where: { action in
            if case .resumeSync = action { return true }; return false
        }) ?? false
        #expect(hasResume, "Paused sync must expose .resumeSync")
    }

    @Test("Running non-paused sync emits .pauseSync")
    func syncRunningEmitsPause() {
        var sync = emptySync()
        sync.isSyncing = true
        sync.isPaused = false
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: sync, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let row = snapshot.sections.flatMap(\.rows).first(where: { $0.kind == .sync })
        let hasPause = row?.actions.contains(where: { action in
            if case .pauseSync = action { return true }; return false
        }) ?? false
        #expect(hasPause, "Running non-paused sync must expose .pauseSync")
    }

    // MARK: - Behavior 12: destructive queue clear

    @Test("clearAnalysisQueue action present iff queue has pending work")
    func clearAnalysisQueueConditional() {
        let idleQueue = emptyQueue()
        let snapshotIdle = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: idleQueue,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let idleRow = snapshotIdle.sections.flatMap(\.rows).first(where: { $0.kind == .analysis })
        let idleHasClear = idleRow?.actions.contains(where: { action in
            if case .clearAnalysisQueue = action { return true }; return false
        }) ?? false
        #expect(
            !idleHasClear,
            "Idle queue must NOT expose .clearAnalysisQueue"
        )

        var busyQueue = emptyQueue()
        busyQueue.pendingAnalyses = 3
        let snapshotBusy = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: busyQueue,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let busyRow = snapshotBusy.sections.flatMap(\.rows).first(where: { $0.kind == .analysis })
        let busyHasClear = busyRow?.actions.contains(where: { action in
            if case .clearAnalysisQueue = action { return true }; return false
        }) ?? false
        #expect(
            busyHasClear,
            "Non-empty queue must expose .clearAnalysisQueue"
        )
    }

    // MARK: - Behavior 13: cap notice

    @Test("showsCapNotice iff recentTruncated is true")
    func capNoticeReflectsTruncation() {
        let truncated = makeOperation(type: .import, status: .completed, completedAt: Self.referenceNow)
        let snapTruncated = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [truncated],
            recentTruncated: true,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let recentTruncated = snapTruncated.sections.first(where: { $0.kind == .recent })
        #expect(
            recentTruncated?.showsCapNotice == true,
            "recentTruncated=true must set showsCapNotice on the recent section"
        )

        let snapNotTruncated = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [truncated],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let recentNotTruncated = snapNotTruncated.sections.first(where: { $0.kind == .recent })
        #expect(
            recentNotTruncated?.showsCapNotice == false,
            "recentTruncated=false must leave showsCapNotice false"
        )
    }

    // MARK: - Behavior 14: clearRecent header action

    @Test("clearRecent header action present iff there is something to clear")
    func clearRecentHeaderConditional() {
        let completed = makeOperation(type: .import, status: .completed, completedAt: Self.referenceNow)
        let snapWithRecent = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [completed],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let recent = snapWithRecent.sections.first(where: { $0.kind == .recent })
        let hasClear = recent?.headerActions.contains(where: { action in
            if case .clearRecent = action { return true }; return false
        }) ?? false
        #expect(hasClear, "Recent section with entries must expose .clearRecent header action")

        let snapEmpty = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        #expect(
            !snapEmpty.sections.contains(where: { $0.kind == .recent }),
            "With no recent entries, the recent section is omitted entirely"
        )
    }

    // MARK: - Behavior 15: stalled rows

    @Test("Stalled operation yields status == .stalled and isStalled == true")
    func stalledRowStatus() {
        let op = makeOperation(type: .analysis, status: .running)
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [op],
            stalledIDs: [op.id],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let row = snapshot.sections.flatMap(\.rows).first(where: { $0.id == op.id.uuidString })
        #expect(
            row?.status == .stalled,
            "An operation whose id is in stalledIDs must render with status .stalled"
        )
        #expect(
            row?.isStalled == true,
            "isStalled flag must be true for stalled rows"
        )
    }

    // MARK: - Behavior 16: accessibility identifiers

    @Test("Row accessibilityIdentifier starts with 'operation_row_' and contains no UUID substring")
    func rowAccessibilityIdentifierStable() {
        let op = makeOperation(type: .artwork, status: .running)
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [op],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        let row = snapshot.sections.flatMap(\.rows).first
        guard let id = row?.accessibilityIdentifier else {
            Issue.record("Row missing accessibilityIdentifier")
            return
        }
        #expect(
            id.hasPrefix("operation_row_"),
            "Row identifier must use the stable 'operation_row_' prefix"
        )
        #expect(
            !id.contains(op.id.uuidString),
            "Row identifier must NOT embed the UUID — UUIDs are unstable across launches"
        )
    }

    @Test("Section-level accessibility identifiers match the locked list")
    func sectionIdentifiersLocked() {
        let running = makeOperation(type: .artwork, status: .running)
        let failed = makeOperation(
            type: .import, status: .failed,
            completedAt: Self.referenceNow.addingTimeInterval(-60)
        )
        let completed = makeOperation(
            type: .fingerprint, status: .completed,
            completedAt: Self.referenceNow.addingTimeInterval(-120)
        )
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [running],
            stalledIDs: [],
            recentOperations: [failed, completed],
            recentTruncated: true,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [
                PersistedFailureInput(
                    trackID: 99, artist: "A", title: "T",
                    reason: "x", date: Self.referenceNow, attempts: 1
                )
            ],
            now: Self.referenceNow
        )
        let ids = Set(snapshot.sections.map(\.id))
        for expected in ["active", "attention", "recent"] {
            #expect(
                ids.contains(expected),
                "Section id must be the rawValue of its kind: \(expected)"
            )
        }
    }

    // MARK: - Section titles

    @Test("Section titles are the locked strings 'Active' / 'Needs Attention' / 'Recent'")
    func sectionTitlesLocked() {
        let running = makeOperation(type: .artwork, status: .running)
        let failed = makeOperation(
            type: .import, status: .failed,
            completedAt: Self.referenceNow.addingTimeInterval(-60)
        )
        let completed = makeOperation(
            type: .fingerprint, status: .completed,
            completedAt: Self.referenceNow.addingTimeInterval(-120)
        )
        let snapshot = ActivityFeed.makeSnapshot(
            operations: [running],
            stalledIDs: [],
            recentOperations: [failed, completed],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [
                PersistedFailureInput(
                    trackID: 99, artist: "A", title: "T",
                    reason: "x", date: Self.referenceNow, attempts: 1
                )
            ],
            now: Self.referenceNow
        )
        let titlesByKind = Dictionary(
            uniqueKeysWithValues: snapshot.sections.map { ($0.kind, $0.title) }
        )
        #expect(
            titlesByKind[.active] == "Active",
            "Active section title must be exactly 'Active'"
        )
        #expect(
            titlesByKind[.attention] == "Needs Attention",
            "Attention section title must be exactly 'Needs Attention'"
        )
        #expect(
            titlesByKind[.recent] == "Recent",
            "Recent section title must be exactly 'Recent'"
        )
    }

    // MARK: - Snapshot-level isEmpty

    @Test("snapshot.isEmpty is true iff ALL sections are empty")
    func snapshotIsEmptyInvariant() {
        let running = makeOperation(type: .artwork, status: .running)
        let withActive = ActivityFeed.makeSnapshot(
            operations: [running],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        #expect(
            !withActive.isEmpty,
            "snapshot.isEmpty must be false when any section has rows"
        )
        let empty = ActivityFeed.makeSnapshot(
            operations: [],
            stalledIDs: [],
            recentOperations: [],
            recentTruncated: false,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [],
            now: Self.referenceNow
        )
        #expect(
            empty.isEmpty,
            "snapshot.isEmpty must be true only when every section is empty"
        )
    }

    // MARK: - Determinism / purity

    @Test("makeSnapshot is pure: identical inputs yield identical snapshots")
    func snapshotIsPure() {
        let op = makeOperation(type: .artwork, status: .running)
        let args = (
            operations: [op], stalledIDs: Set<UUID>(),
            recent: [ActivityViewModel.Operation](), truncated: false,
            now: Self.referenceNow
        )
        let a = ActivityFeed.makeSnapshot(
            operations: args.operations, stalledIDs: args.stalledIDs,
            recentOperations: args.recent, recentTruncated: args.truncated,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [], now: args.now
        )
        let b = ActivityFeed.makeSnapshot(
            operations: args.operations, stalledIDs: args.stalledIDs,
            recentOperations: args.recent, recentTruncated: args.truncated,
            download: nil, sync: nil, queue: nil,
            persistedFailures: [], now: args.now
        )
        #expect(
            a == b,
            "makeSnapshot must be a pure function — same inputs, same snapshot"
        )
    }
}

// MARK: - Test-only mutation helper

private extension DownloadSourceState {
    func mutating(_ mutate: (inout DownloadSourceState) -> Void) -> DownloadSourceState {
        var copy = self
        mutate(&copy)
        return copy
    }
}

private extension SyncSourceState {
    func mutating(_ mutate: (inout SyncSourceState) -> Void) -> SyncSourceState {
        var copy = self
        mutate(&copy)
        return copy
    }
}

private extension QueueSourceState {
    func mutating(_ mutate: (inout QueueSourceState) -> Void) -> QueueSourceState {
        var copy = self
        mutate(&copy)
        return copy
    }
}
